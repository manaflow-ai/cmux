// The path, default and engines are generated from schemas/settings/source/home.json
// (Schema/SettingsSchema+Home.generated.swift).

/// `home.chiefEngine` in cmux.json: which Chief Home opens (Leo's list 89(3); #64 decided the
/// default). `auto`, the default, is this Mac's Chief while this Mac's optchat-chief runs, else
/// the Hosted (cloud) Chief; `local` and `hosted` force one. Settings > Chief draws it as the Engine
/// row that leads the Chiefs card; each Chief's own harness stays in its editor. Only the person
/// picks it: it decides whether their messages go to this Mac or the cloud.
public nonisolated struct HomeChiefEngineSetting {
    public nonisolated init() {}

    /// The engine id; one that is not an engine is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let id = value.stringValue, values.contains(id) else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                      message: "expected one of " + values.joined(separator: ", ")))
        }
        return (id, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `home.chiefEngine` (``HomeChiefEngineSetting``), read from the merged root so a managed value applies.
    public var homeChiefEngine: String { HomeChiefEngineSetting.parse(root).0 }
}
