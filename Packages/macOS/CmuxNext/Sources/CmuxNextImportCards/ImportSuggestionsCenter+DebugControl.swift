#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings

extension ImportSuggestionsCenter {
    /// `debug.import_note` (DEBUG and bench builds): the sidebar's import note for captures on a Mac
    /// with no Conductor.
    ///
    /// - Parameter params: `action`: `state` (default) or `show` (a stand-in Conductor finding, the
    ///   note's x reopened; ``showConductorNoteFixture(workspaces:)``).
    /// - Returns: whether the note shows, whether import suggestions are on, and the ids of the findings.
    public func debugImportNote(_ params: [String: JSONValue]) -> JSONValue {
        if params["action"]?.stringValue == "show" { showConductorNoteFixture() }
        return .object([
            "note": .bool(conductorNote != nil),
            "enabled": .bool(isEnabled),
            "findings": .array(findings.map { .string($0.id) }),
        ])
    }
}
#endif
