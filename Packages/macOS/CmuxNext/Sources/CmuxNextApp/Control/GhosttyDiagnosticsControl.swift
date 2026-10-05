import CmuxNextControl
import CmuxNextSettings
import CmuxNextTerminal

/// `ghostty.diagnostics` (R92): the Ghostty config keys and keybind actions
/// of the user's files that cmux does not apply, each with its file, line,
/// reason and cmux replacement, and the lines libghostty could not read.
/// The Settings page's Ghostty config group shows the same report.
@MainActor
struct GhosttyDiagnosticsControl {
    /// The applied config's diagnostics (`GhosttyDiagnosticsModel`).
    let diagnostics: @MainActor () -> [GhosttyConfigDiagnostic]
    /// The files behind it, in load order.
    let files: @MainActor () -> [String]

    static let methodName = "ghostty.diagnostics"

    init(diagnostics: @escaping @MainActor () -> [GhosttyConfigDiagnostic] = { GhosttyDiagnosticsModel.shared.diagnostics },
         files: @escaping @MainActor () -> [String] = { GhosttyDiagnosticsModel.shared.files }) {
        self.diagnostics = diagnostics
        self.files = files
    }

    var method: ControlMethod {
        let control = self
        return .mainActor(Self.methodName) { _ in .value(control.report()) }
    }

    func report() -> JSONValue {
        .object([
            "files": .array(files().map(JSONValue.string)),
            "diagnostics": .array(diagnostics().map(Self.json)),
        ])
    }

    static func json(_ diagnostic: GhosttyConfigDiagnostic) -> JSONValue {
        .object([
            "kind": .string(diagnostic.kind.rawValue),
            "name": .string(diagnostic.name),
            "file": diagnostic.file.map(JSONValue.string) ?? .null,
            "line": diagnostic.line.map { .number(Double($0)) } ?? .null,
            "reason": diagnostic.support.map { .string($0.reason.rawValue) } ?? .null,
            "replacement": diagnostic.support?.replacement.map(JSONValue.string) ?? .null,
        ])
    }
}
