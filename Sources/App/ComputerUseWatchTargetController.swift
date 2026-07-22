import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Dedupe decision (pure, injectable)

/// Pure focus-activation policy for the computer-use "watch the target" feature.
///
/// A computer-use agent runs as a background CLI process, which macOS will not
/// reliably let front an app over the currently-active GUI app (cmux). cmux *is*
/// the active app, so cmux fronts the driven target on the driver's behalf — but
/// only when a *new* target starts being driven, never on every action.
enum ComputerUseWatchTargetDecision {
    /// Returns the target pid cmux should bring to the front, or `nil` to do nothing.
    ///
    /// The rule is intentionally minimal so it never fights the user's focus:
    /// - `current == nil` (no session is actively driving) -> `nil`, and the caller
    ///   keeps `lastActivated` unchanged. This is what makes a brief idle gap
    ///   between actions harmless: when the same target resumes, it still equals
    ///   `lastActivated`, so we do not re-front it.
    /// - `current == lastActivated` (the same app keeps being driven) -> `nil`.
    ///   Every action rewrites the driver state file and the user may have clicked
    ///   away in the meantime; returning `nil` here is precisely what stops cmux
    ///   from yanking focus back on every click.
    /// - otherwise a *different* app is now being driven -> return `current` so the
    ///   caller activates it once and records it as `lastActivated`.
    static func activation(
        current: Int?,
        lastActivated: Int?,
        automaticActivationEnabled: Bool = true
    ) -> Int? {
        guard automaticActivationEnabled else { return nil }
        guard let current else { return nil }
        if current == lastActivated { return nil }
        return current
    }
}

// MARK: - Fresh-state scanning (pure)

/// Selects the driver state file for the session that is *currently* driving an
/// app, from the same untrusted state directory the cursor overlay watches.
struct ComputerUseWatchTargetFeed: Sendable {
    /// A state file counts as "actively driving" only while its `last_action_at`
    /// is within this window; the driver rewrites the file on every action.
    static let defaultFreshnessInterval: TimeInterval = 5
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60
    private static let maximumFileBytes = 64 * 1_024
    private static let cursorSuffix = ".cursor.json"
    private static let stateSuffix = ".json"

    let freshnessInterval: TimeInterval

    init(freshnessInterval: TimeInterval = Self.defaultFreshnessInterval) {
        self.freshnessInterval = freshnessInterval
    }

    /// Returns the most-recently-updated fresh driver state, or `nil` when nothing
    /// is actively driving right now.
    func scan(
        directoryURL: URL,
        now: Date,
        fileManager: FileManager = .default
    ) -> ComputerUseDriverState? {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        var best: ComputerUseDriverState?
        for url in urls {
            let name = url.lastPathComponent
            // `.cursor.json` files live in the same directory; they never parse as a
            // driver state, but skip them explicitly to keep the scan cheap.
            guard name.hasSuffix(Self.stateSuffix), !name.hasSuffix(Self.cursorSuffix) else { continue }
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= Self.maximumFileBytes,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                let state = ComputerUseDriverState(data: data),
                isFresh(state.lastActionAt, now: now)
            else {
                continue
            }
            if let current = best, current.lastActionAt >= state.lastActionAt { continue }
            best = state
        }
        return best
    }

    func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -Self.maximumFutureClockSkew && age <= freshnessInterval
    }
}

// MARK: - Controller

/// Brings the app a local computer-use driver is steering to the front so the
/// user can actually watch the automation, instead of seeing the cmux-hosted
/// cursor click on top of cmux while the real target stays hidden behind it.
///
/// Fronts each distinct target exactly once (`ComputerUseWatchTargetDecision`)
/// so it never competes with the user's own focus while a session runs. Gated by
/// `featureEnabled` and validated with `ComputerUseTargetIdentity`, mirroring the
/// menu bar's "View Computer Use" action and the cursor overlay's watcher/poll shape.
/// Choosing "Continue in Background" pauses automatic activation until the user
/// explicitly returns to the target or the active session ends.
@MainActor
final class ComputerUseWatchTargetController {
    private let stateDirectoryURL: URL
    private let featureEnabled: @MainActor () -> Bool
    private let feed: ComputerUseWatchTargetFeed
    private let pollInterval: TimeInterval
    private let activate: @MainActor (NSRunningApplication) -> Void

    /// Whether automation should keep running without automatically fronting its target.
    private(set) var isRunningInBackground = false

    /// The pid of the target we most recently fronted. Persists across idle gaps
    /// so a paused-then-resumed same target is not re-fronted; only reset when a
    /// genuinely different target begins being driven.
    private var lastActivatedTargetPID: Int?

    private var directoryWatchSource: DispatchSourceFileSystemObject?
    private let directoryWatchQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseWatchTarget")
    /// The untrusted state directory is scanned here, never on the main thread.
    private let scanQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseWatchTargetScan", qos: .utility)
    /// At most one background scan is outstanding; further ticks are dropped until
    /// it lands, which collapses a burst of watcher/timer events into one scan.
    private var scanInFlight = false
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshCoalesceScheduled = false
    private var started = false

    init(
        stateDirectoryURL: URL,
        featureEnabled: @escaping @MainActor () -> Bool,
        feed: ComputerUseWatchTargetFeed = ComputerUseWatchTargetFeed(),
        pollInterval: TimeInterval = 0.75,
        activate: @escaping @MainActor (NSRunningApplication) -> Void = { application in
            // NSRunningApplication.activate no longer reliably fronts another app
            // on macOS 14+ (cooperative-activation changes make it a frequent
            // no-op). NSWorkspace.openApplication on the already-running app's
            // bundle brings it genuinely to the front — no Apple Events permission
            // needed — which is what "watch the automation" requires.
            if let bundleURL = application.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }
            } else {
                _ = application.activate(options: [.activateAllWindows])
            }
        }
    ) {
        self.stateDirectoryURL = stateDirectoryURL
        self.featureEnabled = featureEnabled
        self.feed = feed
        self.pollInterval = pollInterval
        self.activate = activate
    }

    deinit {
        directoryWatchSource?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.publisher(for: .cmuxFeatureFlagsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        startWatchingStateDirectory()
        // The watcher fires on writes, but the driver stops writing between actions;
        // a light poll picks up a new target promptly even without a write event.
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        refresh()
    }

    func stop() {
        started = false
        scanInFlight = false
        cancellables.removeAll()
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
        lastActivatedTargetPID = nil
        isRunningInBackground = false
    }

    /// Preserves the originating terminal as the user's foreground context.
    func continueInBackground() {
        isRunningInBackground = true
    }

    /// Fronts a validated target and resumes automatic following for new targets.
    @discardableResult
    func viewTarget(_ identity: ComputerUseTargetIdentity) -> Bool {
        guard
            let pid = pid_t(exactly: identity.processIdentifier),
            let application = NSRunningApplication(processIdentifier: pid),
            identity.matches(application)
        else {
            return false
        }

        isRunningInBackground = false
        activate(application)
        lastActivatedTargetPID = identity.processIdentifier
        return true
    }

    /// Reports whether a captured target still identifies the same running app.
    func canViewTarget(_ identity: ComputerUseTargetIdentity) -> Bool {
        guard let pid = pid_t(exactly: identity.processIdentifier) else { return false }
        return identity.matches(NSRunningApplication(processIdentifier: pid))
    }

    /// Restores visible follow mode for the next Computer Use session.
    func resetPresentationMode() {
        isRunningInBackground = false
        lastActivatedTargetPID = nil
    }

    func refresh() {
        // Feature off: do nothing and, crucially, leave `lastActivatedTargetPID`
        // untouched so toggling off/on does not re-front the same live target.
        guard featureEnabled(), !isRunningInBackground else { return }

        // Never scan the untrusted state directory on the main thread. The driver
        // rewrites its state files many times per second while driving, so doing
        // the directory enumeration + JSON reads inline here floods the main
        // thread with synchronous filesystem I/O and beachballs the app during
        // active computer use. Run the I/O on a utility queue and validate +
        // activate back on the main actor with the small `Sendable` snapshot;
        // `scanInFlight` collapses a burst of watcher/timer events into one scan.
        guard !scanInFlight else { return }
        scanInFlight = true
        let feed = self.feed
        let directoryURL = self.stateDirectoryURL
        scanQueue.async { [weak self] in
            let state = feed.scan(directoryURL: directoryURL, now: Date())
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                self.applyScannedState(state)
            }
        }
    }

    private func applyScannedState(_ state: ComputerUseDriverState?) {
        guard featureEnabled() else { return }

        let current = validatedTargetPID(from: state)
        guard
            let pidToActivate = ComputerUseWatchTargetDecision.activation(
                current: current,
                lastActivated: lastActivatedTargetPID,
                automaticActivationEnabled: !isRunningInBackground
            ),
            let pid = pid_t(exactly: pidToActivate),
            let application = NSRunningApplication(processIdentifier: pid)
        else {
            return
        }

        activate(application)
        // Record the attempt regardless of the activation return value so a target
        // that resists activation is not re-fronted on every poll (focus-fighting).
        lastActivatedTargetPID = pidToActivate
    }

    /// Validates the scanned driver state's target against liveness + identity to
    /// reject reused/stale pids. Returns `nil` when nothing is driving or the
    /// target fails validation. Runs on the main actor (touches `NSRunningApplication`).
    private func validatedTargetPID(from state: ComputerUseDriverState?) -> Int? {
        guard
            let state,
            let pid = pid_t(exactly: state.targetPID),
            // Never front cmux itself — only the external app under automation.
            pid != ProcessInfo.processInfo.processIdentifier,
            let application = NSRunningApplication(processIdentifier: pid),
            ComputerUseTargetIdentity(state: state, runningApplication: application) != nil
        else {
            return nil
        }
        return Int(pid)
    }

    private func startWatchingStateDirectory() {
        guard directoryWatchSource == nil else { return }
        try? FileManager.default.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
        let descriptor = open(stateDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: directoryWatchQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleCoalescedRefresh() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        directoryWatchSource = source
    }

    /// Coalesce a burst of filesystem events into at most one refresh per ~quarter
    /// second. The driver rewrites its state file on every action; this only needs
    /// to notice a *new* target, so refreshing on every raw event would needlessly
    /// flood the main thread during active computer use.
    private func scheduleCoalescedRefresh() {
        guard started, !refreshCoalesceScheduled else { return }
        refreshCoalesceScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.refreshCoalesceScheduled = false
            self.refresh()
        }
    }
}
