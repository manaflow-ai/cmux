import CmuxNextCompat
import CmuxNextComputerUse
import Darwin
public import Foundation
import os

/// The Screen Sharing helper (plans/cmux-next/screen-sharing-helper.md): the signed app
/// `<app> Screen Sharing.app` in `Contents/Library`, whose executable is the cmux.rd/1 host
/// (`cmux-rd`, cmux-tui/crates/cmux-rd-host). It holds this Mac's Screen Recording and
/// Accessibility grants for screen sharing, so macOS prompts for, lists and restarts the
/// helper, never cmux: a grant never relaunches this app. Each use is a fresh helper process
/// (the permission probe, a request, one session's `serve`), started from its verified copy
/// outside the app with responsibility disclaimed (``SignedHelperLaunch``); closing its stdin,
/// or this app ending, ends it.
public nonisolated final class MacScreenHelper: Sendable {
    /// The helper's executable inside its bundle.
    static let executableName = "cmux-screen-sharing"
    /// Every channel's helper bundle ends with this (`cmux NIGHTLY Screen Sharing.app`).
    static let bundleSuffix = " Screen Sharing.app"

    /// The bundled helper app (`CMUX_NEXT_SCREEN_HELPER_APP` in development), its name without
    /// `.app` (what System Settings lists), and the launch that stages and starts it.
    public let app: URL
    let name: String
    private let launch: SignedHelperLaunch
    /// The staged executable, once staged (a later stage reuses a matching copy anyway).
    private let staged = Mutex<URL?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mac-screen-helper")

    /// How long a short command (a probe, a request) may take before it is ended.
    private let clock: any Clock<Duration>

    init(app: URL, launch: SignedHelperLaunch = .screenSharing(), clock: any Clock<Duration> = ContinuousClock()) {
        self.app = app
        name = String(app.deletingPathExtension().lastPathComponent)
        self.launch = launch
        self.clock = clock
    }

    /// This build's helper, or nil when it carries none (a build without the helper serves and
    /// checks permissions in the app, as before the helper). A disk lookup: call it off the main
    /// actor; ``MacScreenShareHost`` keeps the one it found.
    public static func bundled(_ bundle: Bundle = .main) -> MacScreenHelper? {
        if let path = ProcessInfo.processInfo.environment["CMUX_NEXT_SCREEN_HELPER_APP"], !path.isEmpty {
            return MacScreenHelper(app: URL(fileURLWithPath: path))
        }
        let library = bundle.bundleURL.appending(path: "Contents/Library", directoryHint: .isDirectory)
        guard let names = try? FileManager.checked.contentsOfDirectory(atPath: library.path),
              let found = names.sorted().first(where: { $0.hasSuffix(bundleSuffix) }) else { return nil }
        let app = library.appending(path: found, directoryHint: .isDirectory)
        guard FileManager.checked.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/\(executableName)").path) else { return nil }
        return MacScreenHelper(app: app)
    }

    /// The helper did not start because its verified copy could not be made: the copy out of
    /// the app failed, or the copy failed its code signature check (``SignedHelperLaunch/stage(_:)``,
    /// the Computer Use helper's pinned Developer ID requirement, or the separate helper's
    /// designated requirement). The viewer's card shows this text, so it names the cause.
    struct NotStaged: LocalizedError {
        var helper: String
        var errorDescription: String? {
            String(format: L.t("macScreen.helper.notStaged", "%@ could not be copied out of cmux, or its copy failed its code signature check"), helper)
        }
    }

    /// The executable of the verified copy to start; nil when it cannot be staged (then the
    /// helper does not run: never from inside this app, where macOS would check cmux instead).
    @concurrent func executable() async -> URL? {
        if let url = staged.withLock({ $0 }), FileManager.checked.isExecutableFile(atPath: url.path) { return url }
        guard let copy = await launch.stage(app) else {
            logger.error("the Screen Sharing helper could not be copied out of the app: \(self.app.path, privacy: .public)")
            return nil
        }
        let url = copy.appending(path: "Contents/MacOS/\(Self.executableName)")
        staged.withLock { $0 = url }
        return url
    }

    /// Starts `arguments` (`serve`) with responsibility disclaimed, its stdio on these pipes.
    static func spawn(_ executable: URL, _ arguments: [String], stdin: Pipe, stdout: Pipe, stderr: Pipe) throws -> pid_t {
        let pid = try SignedHelperLaunch.spawn(executable: executable, arguments: arguments,
                                               stdin: stdin.fileHandleForReading.fileDescriptor,
                                               stdout: stdout.fileHandleForWriting.fileDescriptor,
                                               stderr: stderr.fileHandleForWriting.fileDescriptor)
        // The child has its own copies; ours would keep the pipes open past its exit.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        return pid
    }

    /// The helper's own grants, or nil when the helper did not answer.
    package struct Permissions: Decodable, Equatable, Sendable {
        package var screenRecording: Bool
        package var accessibility: Bool

        enum CodingKeys: String, CodingKey {
            case screenRecording = "screen_recording"
            case accessibility
        }
    }

    /// `permissions`: a fresh helper reads its own grants and exits (no prompt).
    @concurrent package func permissions() async -> Permissions? {
        await answer(["permissions"])
    }

    /// `request-permission screen-recording|accessibility`: macOS's prompt for the helper, then
    /// the helper's grants (still off until the person answers macOS).
    @concurrent func request(screenRecording: Bool) async -> Permissions? {
        await answer(["request-permission", screenRecording ? "screen-recording" : "accessibility"])
    }

    @concurrent static func requestBundledGrant(_ permission: String) async {
        _ = await bundled()?.request(screenRecording: permission == "screen-recording")
    }

    /// Runs one short helper command and decodes its one JSON line. Bounded: a helper that does
    /// not answer within 10 s is ended and reads as no answer.
    @concurrent private func answer(_ arguments: [String]) async -> Permissions? {
        guard let executable = await executable() else { return nil }
        switch await SignedHelperLaunch.answer(executable: executable, arguments: arguments, as: Permissions.self, clock: clock) {
        case let .success(permissions): return permissions
        case let .failure(.notStarted(reason)):
            logger.error("the Screen Sharing helper did not start: \(reason, privacy: .public)")
        case .failure(.noAnswer):
            logger.error("the Screen Sharing helper gave no answer to \(arguments.first ?? "", privacy: .public)")
        }
        return nil
    }
}
