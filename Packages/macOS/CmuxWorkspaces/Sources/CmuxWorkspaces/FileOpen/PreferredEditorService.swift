public import Foundation
public import CmuxSettings
public import CmuxTestSupport

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
///    stdio; a launch failure or a nonzero exit (e.g. command-not-found
///    exiting 127) falls back to the system default handler.
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

    /// Creates a service with explicit collaborators (tests pass fakes).
    ///
    /// - Parameters:
    ///   - editor: Source of the configured editor command.
    ///   - capture: UI-test capture seam consulted before any real open.
    ///   - systemOpener: Fallback opener for the no-command and
    ///     failed-command paths.
    public init(
        editor: any PreferredEditorReading,
        capture: any TestCaptureWriting,
        systemOpener: any SystemFileOpening
    ) {
        self.editor = editor
        self.capture = capture
        self.systemOpener = systemOpener
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
        // A `#L<line>[:<column>]` fragment (set by terminal `path:line` links)
        // travels to goto-capable editors as a `path:line:column` argument; the
        // system-open fallback always uses the fragment-free file URL.
        let path = url.path
        if capture.appendLineIfConfigured(
            envKey: "CMUX_UI_TEST_CAPTURE_OPEN_PATH",
            line: path
        ) {
            return
        }

        let fallbackURL = URL(fileURLWithPath: path)

        guard let command = editor.resolvedCommand else {
            systemOpener.openWithSystemDefault(fallbackURL)
            return
        }

        let invocation = Self.editorInvocation(forURL: url, command: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "\(command)\(invocation.gotoFlag) \(invocation.argument.posixShellSingleQuoted)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let systemOpener = self.systemOpener
        process.terminationHandler = { @Sendable process in
            // Fall back when the command fails (e.g. command not found exits
            // 127 but /bin/sh itself launched fine).
            guard process.terminationStatus != 0 else { return }
            Task { @MainActor in
                systemOpener.openWithSystemDefault(fallbackURL)
            }
        }

        do {
            try process.run()
        } catch {
            systemOpener.openWithSystemDefault(fallbackURL)
        }
    }
}

extension PreferredEditorService {
    /// Editors whose CLI understands a `path:line[:column]` goto argument.
    private static let gotoEditorCommandNames: Set<String> = [
        "code", "code-insiders", "cursor", "cursor-insiders", "windsurf",
    ]

    /// Builds the goto flag and file argument for `command` opening `url`.
    ///
    /// With no `#L` fragment, or for an editor that is not goto-capable, this
    /// is the bare file path. For a goto-capable editor with a line fragment,
    /// the argument becomes `path:line[:column]` and ` -g` is prepended unless
    /// the configured command already carries `-g`/`--goto`.
    ///
    /// Every shell word is scanned for a recognized editor name, not just the
    /// first, so a wrapper prefix (`arch -arm64 code`, `env VAR=1 code`) still
    /// resolves the goto flag.
    static func editorInvocation(
        forURL url: URL,
        command: String
    ) -> (gotoFlag: String, argument: String) {
        let path = url.path
        guard let reference = lineColumn(fromFragment: url.fragment) else {
            return (gotoFlag: "", argument: path)
        }

        let tokens = commandTokens(command)
        let isGotoEditor = tokens.contains { token in
            gotoEditorCommandNames.contains((token as NSString).lastPathComponent.lowercased())
        }
        guard isGotoEditor else {
            return (gotoFlag: "", argument: path)
        }

        let argument = reference.column.map { "\(path):\(reference.line):\($0)" }
            ?? "\(path):\(reference.line)"
        let hasGotoFlag = tokens.contains("-g") || tokens.contains("--goto")
        return (gotoFlag: hasGotoFlag ? "" : " -g", argument: argument)
    }

    /// Parses a `#L<line>[:<column>]` fragment into positive integers.
    private static func lineColumn(fromFragment fragment: String?) -> (line: Int, column: Int?)? {
        guard var raw = fragment?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw.first == "L" || raw.first == "l" {
            raw.removeFirst()
        }
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let linePart = parts.first,
              let line = Int(linePart),
              line > 0 else {
            return nil
        }
        if parts.count == 2, let column = Int(parts[1]), column > 0 {
            return (line, column)
        }
        return (line, nil)
    }

    /// Splits a configured editor command into shell words. Single and double
    /// quotes keep a binary path with spaces (a quoted app bundle) as one token;
    /// an unquoted backslash escapes the next character, so a backslash-escaped
    /// path stays one token too. Backslashes are literal inside quotes, matching
    /// how `/bin/sh -c` word-splits the command that is actually run — so a
    /// quoted arg like `"\--goto"` is not misread as the `--goto` flag.
    private static func commandTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasToken = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                hasToken = true
                continue
            }
            if character == "\\", quote == nil {
                escaping = true
                hasToken = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasToken = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasToken = true
                continue
            }
            if character.isWhitespace {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(character)
            hasToken = true
        }
        if escaping {
            current.append("\\")
        }
        if hasToken {
            tokens.append(current)
        }
        return tokens
    }
}
