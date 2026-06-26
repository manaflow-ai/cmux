public import Foundation
public import CmuxSettings
public import CmuxTestSupport
internal import OSLog

private let preferredEditorLogger = Logger(subsystem: "com.cmuxterm.app", category: "PreferredEditor")

/// Opens files in the user's preferred editor, falling back to the system
/// default handler — the launch path lifted from the legacy
/// `PreferredEditorSettings.open`.
///
/// Behavior, kept faithful to the legacy namespace:
/// 1. When a UI-test capture file is configured under
///    `CMUX_UI_TEST_CAPTURE_OPEN_PATH`, the open is recorded there and
///    intercepted (no process or system open).
/// 2. With no configured editor command, the file opens with the system
///    default handler.
/// 3. Otherwise `/bin/sh -c "<command> '<path>'"` is spawned with silenced
///    stdio and a PATH that includes common GUI-missing CLI directories; a
///    launch failure or a nonzero exit is logged and falls back to the system
///    default handler.
///
/// Isolation: `@MainActor`, because every caller is a main-thread UI flow
/// and the legacy code spawned the editor process synchronously on the
/// calling (main) thread; co-locating keeps the spawn timing identical.
/// Exit status is observed via `Process.terminationHandler` (replacing the
/// legacy `DispatchQueue.global` + `waitUntilExit` hop); the handler hops
/// back to the main actor for the fallback open, matching the legacy
/// `DispatchQueue.main.async` fallback.
@MainActor
public struct PreferredEditorService: FileOpening {
    private let editor: any PreferredEditorReading
    private let capture: any TestCaptureWriting
    private let systemOpener: any SystemFileOpening
    private let environment: [String: String]
    private let fallbackSearchDirectories: [String]

    /// Creates a service with explicit collaborators (tests pass fakes).
    ///
    /// - Parameters:
    ///   - editor: Source of the configured editor command.
    ///   - capture: UI-test capture seam consulted before any real open.
    ///   - systemOpener: Fallback opener for the no-command and
    ///     failed-command paths.
    ///   - environment: Base environment for the editor process.
    ///   - fallbackSearchDirectories: Extra command-search directories that
    ///     should be available to bare editor commands launched from the app.
    public init(
        editor: any PreferredEditorReading,
        capture: any TestCaptureWriting,
        systemOpener: any SystemFileOpening,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackSearchDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    ) {
        self.editor = editor
        self.capture = capture
        self.systemOpener = systemOpener
        self.environment = environment
        self.fallbackSearchDirectories = fallbackSearchDirectories
    }

    /// Creates the production service: editor command from `defaults`,
    /// capture from the process environment, fallback through `NSWorkspace`.
    public init(defaults: UserDefaults) {
        self.init(
            editor: PreferredEditorSettingsStore(defaults: defaults),
            capture: UITestCaptureSink(),
            systemOpener: NSWorkspaceFileOpener()
        )
    }

    public func open(_ url: URL) {
        let path = url.path(percentEncoded: false)
        if capture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: path
        ) {
            return
        }

        guard let command = editor.resolvedCommand else {
            systemOpener.openWithSystemDefault(url)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \(path.posixShellSingleQuoted)"]
        process.environment = Self.launchEnvironment(
            base: environment,
            fallbackSearchDirectories: fallbackSearchDirectories
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let systemOpener = self.systemOpener
        process.terminationHandler = { @Sendable process in
            // Fall back when the command fails (e.g. command not found exits
            // 127 but /bin/sh itself launched fine).
            guard process.terminationStatus != 0 else { return }
            preferredEditorLogger.error(
                """
                Preferred editor command exited with status \
                \(process.terminationStatus, privacy: .public) for \
                \(path, privacy: .private); falling back to the OS default handler
                """
            )
            Task { @MainActor in
                systemOpener.openWithSystemDefault(url)
            }
        }

        do {
            try process.run()
        } catch {
            preferredEditorLogger.error(
                """
                Failed to launch preferred editor shell for \
                \(path, privacy: .private): \
                \(error.localizedDescription, privacy: .public); falling back to \
                the OS default handler
                """
            )
            systemOpener.openWithSystemDefault(url)
        }
    }

    private static func launchEnvironment(
        base: [String: String],
        fallbackSearchDirectories: [String]
    ) -> [String: String] {
        var result = base
        var pathEntries = base["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        var seenPathEntries = Set(pathEntries)

        for directory in fallbackSearchDirectories {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenPathEntries.insert(trimmed).inserted else {
                continue
            }
            pathEntries.append(trimmed)
        }

        result["PATH"] = pathEntries.joined(separator: ":")
        return result
    }
}
