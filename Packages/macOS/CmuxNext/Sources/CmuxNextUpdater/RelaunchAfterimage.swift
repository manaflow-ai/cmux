public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
import Darwin
public import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// A relaunch with no gap on screen (Leo, 2026-11-22: "we need to have far more graceful reloads that appear to just
/// be instantly gracefully transitioned ... no shift, no anything, just... ok now it changed").
///
/// Every relaunch (Restart to Update, an installed build, a build switch or rollback, a language change) ends this
/// process before the new one draws: the quit's saves, an installer's swap and the new launch leave one to three
/// seconds with no cmux window on screen. Here, as the relaunch is decided, each window on screen is pictured
/// (`screenshotImage()`: this process's own window with its Chromium pages, no Screen Recording grant) and handed to an
/// afterimage process, `relaunch-afterimage.js` under `/usr/bin/osascript`, that shows each picture at its window's
/// frame and place in the window order, outlives this process, and leaves once the new process drew its restored
/// windows (``newCopyDrew(stateDirectory:)``) or at ``deadline`` (a short fade). osascript is not this app to
/// LaunchServices, so the relaunch's `open` still starts the new copy. The afterimage owns no state; the restore is the
/// new process's own (window records, launch images, composer wakes), unchanged.
@MainActor public final class RelaunchAfterimage {
    nonisolated private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "relaunch")
    /// The folder, in the build's state folder, that holds the plan and the pictures while the afterimage is up.
    nonisolated public static let folderName = "relaunch-afterimage"
    /// The longest the pictures stay when no new copy draws (a relaunch that failed); then they fade.
    nonisolated static let deadline: Duration = .seconds(8)
    /// A folder older than this at launch is a leftover (its afterimage is gone): removed, never answered.
    nonisolated static let staleAge: TimeInterval = 30
    /// The longest the pictures may take to come up; past it the relaunch goes as before (windows leave at once).
    nonisolated static let shownLimitMilliseconds = 1500

    private let folder: URL?
    private let script: URL?
    private var state: State = .idle
    private var waiters: [@MainActor () -> Void] = []
    private enum State { case idle, starting, shown, failed }

    /// `relaunch-afterimage.js` in this module's resources.
    nonisolated static var bundledScript: URL? { Bundle.module.url(forResource: "relaunch-afterimage", withExtension: "js") }

    public convenience init(stateDirectory: URL?) {
        self.init(stateDirectory: stateDirectory, script: Self.bundledScript)
    }

    init(stateDirectory: URL?, script: URL?) {
        folder = stateDirectory?.appending(path: Self.folderName, directoryHint: .isDirectory)
        self.script = script
    }

    /// True while the pictures are being made or are up: the old windows stay until ``whenShown(_:)`` runs.
    public var isActive: Bool { state == .starting || state == .shown }

    /// Pictures each window on screen now and starts the afterimage; false when there is nothing to picture or no
    /// folder. `activates`: the afterimage takes the front (the person is in cmux, and the new copy comes forward).
    @discardableResult
    public func begin(activates: Bool) -> Bool {
        guard state == .idle || state == .failed, let folder, let script else { return false }
        let windows = Self.shown(NSApp.orderedWindows)
        guard !windows.isEmpty else { return false }
        state = .starting
        let started = ContinuousClock.now
        // task-owner: the pictures, their files and the afterimage's start, once per relaunch; ends in `started`.
        Task { [weak self] in
            var pictures: [Picture] = []
            for window in windows {
                // The window server's image with its child windows (the Chromium pages) composited, as on screen.
                // perf-gate-ok: once per relaunch, as the process ends; never on a theme change or a frame.
                guard let image = try? await window.screenshotImage() else { continue }
                pictures.append(Picture(number: window.windowNumber, frame: window.frame, image: image))
            }
            let made = pictures
            let up = await Task.detached(priority: .userInitiated) { await Self.start(made, activates: activates, folder: folder, script: script) }.value
            Self.logger.notice("relaunch afterimage: \(made.count, privacy: .public) of \(windows.count, privacy: .public) window(s), \(up ? "up" : "failed", privacy: .public) in \(started.duration(to: .now), privacy: .public)")
            self?.started(up)
        }
        return true
    }

    /// Runs `work` once the pictures are on screen, or at once when there is no afterimage (or it failed).
    public func whenShown(_ work: @escaping @MainActor () -> Void) {
        switch state {
        case .starting: waiters.append(work)
        case .idle, .shown, .failed: work()
        }
    }

    /// Waits until the pictures are on screen, at most `limit`: the quit's last step, so this process never leaves
    /// the screen before them.
    public func untilShown(limit: Duration) async {
        guard state == .starting else { return }
        let timer = DemandTimer(owner: "RelaunchAfterimage.untilShown")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            waiters.append { once.resume() }
            timer.schedule(after: limit) { @MainActor in once.resume() }
        }
        timer.cancel()
    }

    /// The relaunch did not happen (a failed install, a refused quit): the afterimage leaves at once (its folder goes).
    public func cancel() {
        guard let folder, state != .idle else { return }
        state = .idle
        flush()
        // task-owner: one folder removal off the main thread.
        Task.detached(priority: .userInitiated) { try? FileManager.checked.removeItem(at: folder) }
    }

    /// Resumes a wait once, whichever of the pictures and the limit comes first.
    private final class Once {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func started(_ up: Bool) {
        guard state == .starting else { return }
        state = up ? .shown : .failed
        flush()
    }

    private func flush() {
        let pending = waiters
        waiters = []
        for work in pending { work() }
    }

    /// Writes the pictures, starts the afterimage and waits (off main) for its `shown` file: the folder's own change
    /// events, never a poll, at most ``shownLimitMilliseconds``.
    nonisolated static func start(_ pictures: [Picture], activates: Bool, folder: URL, script: URL) async -> Bool {
        guard !pictures.isEmpty, write(pictures, activates: activates, to: folder) else { return false }
        let shown = folder.appending(path: "shown", directoryHint: .notDirectory).path
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }
        let (changes, sink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global(qos: .userInitiated))
        source.setEventHandler { sink.yield() }
        source.setCancelHandler { close(descriptor); sink.finish() }
        source.resume()
        let limit = DemandTimer(owner: "RelaunchAfterimage.shown")
        defer { limit.cancel(); source.cancel() }
        // The bound ends the watch, and with it the wait below.
        limit.schedule(after: .milliseconds(shownLimitMilliseconds)) { source.cancel() }
        guard spawn(script: script, folder: folder) else { return false }
        if FileManager.checked.fileExists(atPath: shown) { return true }
        for await _ in changes where FileManager.checked.fileExists(atPath: shown) { return true }
        return FileManager.checked.fileExists(atPath: shown)
    }

    /// The restore placed its windows: a frame later (they drew), the last relaunch's afterimage leaves.
    public func newCopyDrew() {
        let folder = folder?.deletingLastPathComponent()
        leaveTimer.schedule(after: .milliseconds(50)) {
            // task-owner: two small file operations off the main thread, once per launch.
            await Task.detached(priority: .userInitiated) { Self.newCopyDrew(stateDirectory: folder) }.value
        }
    }

    private let leaveTimer = DemandTimer(owner: "RelaunchAfterimage.leave")

    /// The new copy restored and drew its windows: the afterimage, if one is up, leaves (it is under them by now).
    /// A leftover folder (no afterimage answers it) is removed.
    nonisolated public static func newCopyDrew(stateDirectory: URL?) {
        guard let folder = stateDirectory?.appending(path: folderName, directoryHint: .isDirectory) else { return }
        let plan = folder.appending(path: "plan.json", directoryHint: .notDirectory)
        guard let made = (try? FileManager.checked.attributesOfItem(atPath: plan.path))?[.modificationDate] as? Date else { return }
        if Date().timeIntervalSince(made) > staleAge {
            try? FileManager.checked.removeItem(at: folder)
        } else {
            _ = FileManager.checked.createFile(atPath: folder.appending(path: "painted", directoryHint: .notDirectory).path, contents: Data())
        }
    }

    // MARK: Pictures

    nonisolated struct Picture: Sendable {
        var number: Int
        var frame: CGRect
        var image: CGImage
    }

    /// The windows a person sees now, back to front: top-level document windows on this space, not minimized, at
    /// least partly uncovered. Child windows (Chromium pages, overlays) are in their parent's picture.
    static func shown(_ orderedWindows: [NSWindow]) -> [NSWindow] {
        orderedWindows.reversed().filter { window in
            window.isVisible && window.parent == nil && window.level == .normal && window.isOnActiveSpace && !window.isMiniaturized
                && window.alphaValue > 0 && window.occlusionState.contains(.visible) && window.frame.width > 1 && window.frame.height > 1
        }
    }

    /// Writes the pictures (PNG) and `plan.json`, which `relaunch-afterimage.js` reads.
    nonisolated static func write(_ pictures: [Picture], activates: Bool, to folder: URL) -> Bool {
        try? FileManager.checked.removeItem(at: folder)
        guard (try? FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        var windows: [[String: Any]] = []
        for (index, picture) in pictures.enumerated() {
            let name = "w\(index).png"
            guard let destination = CGImageDestinationCreateWithURL(folder.appending(path: name, directoryHint: .notDirectory) as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(destination, picture.image, nil)
            guard CGImageDestinationFinalize(destination) else { return false }
            windows.append(["image": name, "x": picture.frame.minX, "y": picture.frame.minY, "w": picture.frame.width,
                            "h": picture.frame.height, "above": picture.number])
        }
        let plan: [String: Any] = ["activates": activates, "deadlineMs": Int(deadline.components.seconds * 1000), "windows": windows]
        guard let data = try? JSONSerialization.data(withJSONObject: plan) else { return false }
        // The plan last: the afterimage reads it first, so every picture it names is on disk.
        return (try? data.blockingWrite(to: folder.appending(path: "plan.json", directoryHint: .notDirectory), options: .atomic)) != nil
    }

    nonisolated static func arguments(script: URL, folder: URL) -> [String] {
        ["/usr/bin/osascript", "-l", "JavaScript", script.path, folder.path]
    }

    /// Starts the afterimage; it outlives this process (nothing it holds is this process's).
    nonisolated static func spawn(script: URL, folder: URL) -> Bool {
        let args = arguments(script: script, folder: folder)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
