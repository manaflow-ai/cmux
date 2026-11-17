import AppKit
import CmuxNextCompat
public import CmuxNextSettings
public import Foundation
import CmuxNextWakeups

/// Settings > Theme > Open Theme File (`cmux.settings.theme.file.open`): opens the active theme file
/// (`appearance.themeFile`, `themes/<name>.json` beside the settings file) in the person's default
/// editor. The theme file logic is the bundled `cmux` (cmux-tui `cli/theme_file.rs`); this only runs it:
///
/// - No theme file active: `cmux theme export --save my-look --use` writes the current look as one
///   (pixel-identical) and picks it; `my-look-2`, `my-look-3`… when the name is taken.
/// - A shipped file with no copy of the person's (`harbor`): `cmux theme export --save <name>` writes
///   an editable copy that looks the same, which then wins over the shipped one.
///
/// Then the person's file opens off the main thread (Finder shows it when no app opens it). The host
/// runs it only for the Settings page itself (`SettingsPageProvider.writer`), as Open Ghostty Config.
@MainActor
public struct SettingsThemeFileOpener {
    /// The app's bundled `cmux`, nil in a build without one.
    let cli: @Sendable () async -> URL?
    /// The settings file the app reads and writes; the CLI is pointed at the same one.
    let settingsFile: @MainActor () -> URL
    /// The settings as last read (`appearance.themeFile`).
    let root: @MainActor () -> JSONValue

    nonisolated static let baseName = "my-look"
    /// The names tried for a new file before giving up (`my-look` … `my-look-100`).
    nonisolated static let nameAttempts = 100
    nonisolated static let exportTimeout: Duration = .seconds(20)

    public init(cli: @escaping @Sendable () async -> URL?, settingsFile: @escaping @MainActor () -> URL,
                root: @escaping @MainActor () -> JSONValue) {
        self.cli = cli
        self.settingsFile = settingsFile
        self.root = root
    }

    /// Makes the file when needed, then opens it; `{}`.
    public func open() async throws -> JSONValue {
        let settingsFile = settingsFile()
        let configDirectory = settingsFile.deletingLastPathComponent()
        let name: String
        if let active = ThemeFileSetting.name(in: root()) {
            name = active
            if await !Self.exists(ThemeFileSetting.url(named: active, configDirectory: configDirectory)) {
                try await export(["theme", "export", "--save", active], settingsFile: settingsFile)
            }
        } else {
            name = try await Self.freeName(configDirectory: configDirectory)
            try await export(["theme", "export", "--save", name, "--use"], settingsFile: settingsFile)
        }
        let url = ThemeFileSetting.url(named: name, configDirectory: configDirectory)
        NSWorkspace.shared.openInBackground(url) { opened in
            if !opened { NSWorkspace.shared.revealInBackground([url]) }
        }
        return .object([:])
    }

    /// `my-look`, else the first free `my-look-N`. File I/O, off the main thread.
    @concurrent nonisolated private static func freeName(configDirectory: URL) async throws -> String {
        for index in 1...nameAttempts {
            let candidate = index == 1 ? baseName : "\(baseName)-\(index)"
            if !FileManager.checked.fileExists(atPath: ThemeFileSetting.url(named: candidate, configDirectory: configDirectory).path) {
                return candidate
            }
        }
        throw PageError(code: "theme.exists", message: "every name from \(baseName) to \(baseName)-\(nameAttempts) is taken")
    }

    /// File I/O, off the main thread.
    @concurrent nonisolated private static func exists(_ url: URL) async -> Bool {
        FileManager.checked.fileExists(atPath: url.path)
    }

    /// Runs the bundled `cmux` on the app's settings file (off the main thread, with a deadline); a
    /// failure carries all the CLI's stderr lines, in order: a failed `--use` prints its cause first and
    /// a rerun hint after it, so the last line alone can drop the cause.
    private func export(_ arguments: [String], settingsFile: URL) async throws {
        guard let binary = await cli() else {
            throw PageError(code: "cmux.page.unavailable", message: "this build has no cmux")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_NEXT_CONFIG_FILE"] = settingsFile.path
        // `.finish`: a page closed mid-export still gets the whole write (and the `--use` after it).
        let request = ProcessRequest(binary, arguments, environment: environment, errorOutput: .separate,
                                     timeout: Self.exportTimeout, onCancel: .finish)
        let outcome: ProcessOutcome
        do {
            outcome = try await AsyncProcess().run(request)
        } catch {
            throw PageError.failed(error, code: "cmux.settings.theme.file_failed")
        }
        guard outcome.succeeded else {
            let lines = String(decoding: outcome.errorOutput, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            throw PageError(code: "cmux.settings.theme.file_failed",
                            message: lines.isEmpty ? "cmux \(arguments.joined(separator: " ")) failed (exit \(outcome.status))"
                                : lines.joined(separator: " "))
        }
    }
}
