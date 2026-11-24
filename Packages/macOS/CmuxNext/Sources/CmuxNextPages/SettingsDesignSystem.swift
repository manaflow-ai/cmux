public import CmuxNextSettings
public import Foundation

/// Settings > Design System (under More) (webviews `DesignSystemCard.tsx`, RFD 0009 slice 8):
/// `cmux.settings.designSystem.state` runs `cmux --json ext design --show --scene` through the
/// bundled CLI and answers its JSON: the design system extension views are drawn with, resolved in
/// Rust layer over layer (cmux, the active theme file's `design` key, design.json beside the settings
/// file), the values cmux changed since the person's recorded base, the layers that did not read,
/// and `scene`, the SDK's own DesignSystemView of it drawn in the CLI's app host. The page only
/// applies those scene ops, so it and an extension's viewer never differ; this type keeps no state.
/// It only reads, so the page may ask for it without a gesture.
@MainActor
public final class SettingsDesignSystem: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.designSystem.state"
    nonisolated static let arguments = ["--json", "ext", "design", "--show", "--scene"]

    private let cli: @MainActor () async -> URL?
    private let settingsFile: @MainActor () -> URL?
    private let runCLI: SettingsCustomizeLibrary.Runner

    /// `settingsFile` points the CLI at the settings file the app reads, so the theme and the
    /// design.json beside it are the app's (``SettingsCustomizeLibrary/environment(_:settingsFile:)``).
    public init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?,
                runCLI: @escaping SettingsCustomizeLibrary.Runner) {
        self.cli = cli
        self.settingsFile = settingsFile
        self.runCLI = runCLI
    }

    /// The app's: the bundled CLI run as a child process, with the library's deadline.
    public convenience init(cli: @escaping @MainActor () async -> URL?, settingsFile: @escaping @MainActor () -> URL?) {
        self.init(cli: cli, settingsFile: settingsFile, runCLI: { try await SettingsCustomizeLibrary.run($0, $1, $2) })
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        guard let binary = await cli() else { throw PageError(code: "cmux.page.unavailable", message: "no cmux CLI") }
        let environment = SettingsCustomizeLibrary.environment(ProcessInfo.processInfo.environment, settingsFile: settingsFile())
        let (status, stdout, stderr) = try await runCLI(binary, Self.arguments, environment)
        guard status == 0, let answer = try? JSONValue.parse(stdout) else {
            let words = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PageError(code: "cmux.page.unavailable", message: words.isEmpty ? "the design system did not read" : words)
        }
        return answer
    }
}
