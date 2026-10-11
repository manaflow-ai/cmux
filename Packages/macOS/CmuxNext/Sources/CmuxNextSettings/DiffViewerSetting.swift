/// The diff page's display keys (`diff.*`, ``DiffViewerSettingsSchema``). The diff host reads
/// them itself (the snapshot keeps nothing); the parser reports a refused value at its key, as it
/// does for every schema key, and the page then uses its default.
nonisolated enum DiffViewerSetting {
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) {
        for descriptor in DiffViewerSettingsSchema.descriptors {
            guard let value = root.value(at: descriptor.path), !descriptor.accepts(value) else { continue }
            let expected = switch descriptor.kind {
            case .toggle: "expected true or false"
            case .choice(let choices): "expected one of " + choices.map { "\"\($0.value)\"" }.joined(separator: ", ")
            default: "invalid value"
            }
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: expected))
        }
    }
}
