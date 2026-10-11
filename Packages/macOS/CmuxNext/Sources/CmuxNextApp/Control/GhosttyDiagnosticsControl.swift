import CmuxNextControl
import CmuxNextSettings
import CmuxNextTerminal

/// `ghostty.diagnostics` (R92): the Ghostty config keys and keybind actions
/// of the user's files that cmux does not apply, each with its file, line,
/// reason and cmux replacement, and the lines libghostty could not read.
/// The Settings page's Ghostty config group shows the same list
/// (`GhosttyDiagnosticsModel`); this computes it fresh for each request.
struct GhosttyDiagnosticsControl: Sendable {
    /// The applied config's snapshot, read on the main actor.
    let snapshot: @MainActor @Sendable () -> GhosttyConfigDiagnosticsSnapshot?

    static let methodName = "ghostty.diagnostics"

    init(snapshot: @escaping @MainActor @Sendable () -> GhosttyConfigDiagnosticsSnapshot? = {
        GhosttyRuntime.shared.configDiagnosticsSnapshot
    }) {
        self.snapshot = snapshot
    }

    var method: ControlMethod {
        let control = self
        return .async(Self.methodName) { _ in await control.report() }
    }

    func report() async -> JSONValue {
        guard let snapshot = await snapshot() else { return .object(["files": .array([]), "diagnostics": .array([])]) }
        let diagnostics = await snapshot.diagnostics()
        return .object([
            "files": .array(snapshot.files.map(JSONValue.string)),
            "diagnostics": .array(diagnostics.map(Self.json)),
        ])
    }

    nonisolated static func json(_ diagnostic: GhosttyConfigDiagnostic) -> JSONValue {
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
