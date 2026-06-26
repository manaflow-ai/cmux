#if DEBUG
public import Foundation

/// The env-derived token name and shell-seed program for the terminal
/// cmd-click XCUITest scenario.
///
/// `TerminalCmdClickUITestRecorder` (app target) drives the live terminal
/// surface, but the file-name resolution and the `clear; for ...; do printf ...`
/// shell program it seeds are pure functions of the
/// `CMUX_UI_TEST_TERMINAL_CMD_CLICK_*` process environment with no AppKit or
/// live-state coupling, so they live here as a tested value type. The recorder
/// constructs one from its environment and reads these fields; it keeps the
/// fixture-directory creation, `FileRouteSettingsStore` writes, capture-file
/// writes, and `cmuxDebugLog` app-side.
///
/// Every field reproduces the legacy inline `AppDelegate` computation
/// byte-for-byte: ``resolvedFileName`` falls back to `"Cmd Click Fixture.txt"`,
/// ``escapedToken`` backslash-escapes spaces, ``baseDisplayToken`` is the
/// absolute fixture path or the bare file name, ``resolvedDisplayMode`` is
/// `"raw"` or `"escaped"`, ``resolvedLineFormat`` is one of
/// `log`/`alt_screen_log`/`osc8`/`grid`, and ``displayToken``/``shellCommand``
/// are the rendered token and the single-quote-escaped seed program for that
/// line format.
public struct TerminalCmdClickScenario: Sendable {
    /// The fixture file name, defaulting to `"Cmd Click Fixture.txt"` when the
    /// `*_FILE_NAME` environment value is missing or empty.
    public let resolvedFileName: String
    /// The fixture file name with spaces backslash-escaped (`a\ b.txt`).
    public let escapedToken: String
    /// The absolute fixture path when `*_DISPLAY_AS_ABSOLUTE_PATH` is `"1"`,
    /// otherwise the bare file name.
    public let baseDisplayToken: String
    /// The resolved display mode, `"raw"` or `"escaped"`.
    public let resolvedDisplayMode: String
    /// The resolved line format: `log`, `alt_screen_log`, `osc8`, or `grid`.
    public let resolvedLineFormat: String
    /// The token string as rendered into the terminal for the resolved line
    /// format.
    public let displayToken: String
    /// The `clear`-prefixed shell program seeded into the terminal to render
    /// the token block for the resolved line format.
    public let shellCommand: String

    /// Builds the scenario from the process environment, reproducing the legacy
    /// inline `AppDelegate` computation exactly.
    ///
    /// - Parameter environment: The `CMUX_UI_TEST_TERMINAL_CMD_CLICK_*` process
    ///   environment.
    public init(environment env: [String: String]) {
        let fixtureDirectory = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayMode = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineFormat = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let linePrefix = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_PREFIX"] ?? ""
        let displaySuffix = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_SUFFIX"] ?? ""
        let displayAsAbsolutePath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_AS_ABSOLUTE_PATH"] == "1"

        let fileName = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFileName = (fileName?.isEmpty == false) ? fileName! : "Cmd Click Fixture.txt"
        let fixtureDirectoryURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        let expectedFileURL = fixtureDirectoryURL.appendingPathComponent(resolvedFileName)
        let escapedToken = resolvedFileName.replacingOccurrences(of: " ", with: "\\ ")
        let baseDisplayToken = displayAsAbsolutePath ? expectedFileURL.path : resolvedFileName
        let resolvedDisplayMode = (displayMode == "raw") ? "raw" : "escaped"
        let resolvedLineFormat: String
        switch lineFormat {
        case "log":
            resolvedLineFormat = "log"
        case "alt_screen_log":
            resolvedLineFormat = "alt_screen_log"
        case "osc8":
            resolvedLineFormat = "osc8"
        default:
            resolvedLineFormat = "grid"
        }
        let displayToken: String
        let shellCommand: String
        switch resolvedLineFormat {
        case "osc8":
            displayToken = resolvedFileName
            let escapedDisplayToken = Self.singleQuotedShellLiteral(displayToken)
            let escapedURL = Self.singleQuotedShellLiteral(expectedFileURL.absoluteString)
            shellCommand = "clear\rfor i in $(seq 1 48); do printf '\\033]8;;%s\\033\\\\%s\\033]8;;\\033\\\\\\n' '\(escapedURL)' '\(escapedDisplayToken)'; done\r"
        case "log":
            displayToken = "\(baseDisplayToken)\(displaySuffix)"
            let blockLine = "\(linePrefix)\(displayToken)"
            let shellBlockLine = Self.singleQuotedShellLiteral(blockLine)
            shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
        case "alt_screen_log":
            displayToken = "\(baseDisplayToken)\(displaySuffix)"
            let blockLine = "\(linePrefix)\(displayToken)"
            let shellBlockLine = Self.singleQuotedShellLiteral(blockLine)
            shellCommand = "clear\rprintf '\\033[?1049h\\033[H\\033[2J'; for i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
        default:
            switch resolvedDisplayMode {
            case "raw":
                displayToken = "\(baseDisplayToken)\(displaySuffix)"
                let blockLine = "\(displayToken)    OtherFile"
                let shellBlockLine = Self.singleQuotedShellLiteral(blockLine)
                shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
            default:
                displayToken = "\(escapedToken)\(displaySuffix)"
                let blockLine = Array(repeating: displayToken, count: 3).joined(separator: " ")
                let shellBlockLine = Self.singleQuotedShellLiteral(blockLine)
                shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
            }
        }

        self.resolvedFileName = resolvedFileName
        self.escapedToken = escapedToken
        self.baseDisplayToken = baseDisplayToken
        self.resolvedDisplayMode = resolvedDisplayMode
        self.resolvedLineFormat = resolvedLineFormat
        self.displayToken = displayToken
        self.shellCommand = shellCommand
    }

    /// Escapes a single-quoted POSIX shell literal by replacing each `'` with
    /// `'"'"'`, matching the legacy inline helper exactly.
    private static func singleQuotedShellLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "'\"'\"'")
    }
}
#endif
