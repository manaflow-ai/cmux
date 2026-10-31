// The paths and defaults are generated from schemas/settings/source/trust.json
// (Schema/SettingsSchema+Trust.generated.swift); this file only parses.

/// `agents.trust.*` in cmux.json: which folders an agent may start in without the trust
/// question. The acpmux daemon reads the same file at each check (trust_auto.rs); the app
/// shows and validates the values. Roots keep the text as written (absolute or `~/` paths):
/// the daemon expands the home folder and resolves symlinks.
public nonisolated struct TrustSettings: Sendable, Equatable {
    /// Off: every folder without an answer asks.
    public var autoTrust = TrustSettings.trustAutoTrustDefault
    /// Folders whose contents are trusted without a question.
    public var projectRoots = TrustSettings.trustProjectRootsDefault
    /// GitHub users and organizations whose repositories are trusted without a question.
    public var ownOrgs = TrustSettings.trustOwnOrgsDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        if let value = root.value(at: trustAutoTrustPath) {
            if let flag = value.boolValue {
                settings.autoTrust = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: trustAutoTrustPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        if let value = root.value(at: trustProjectRootsPath) {
            let path = trustProjectRootsPath.joined(separator: ".")
            if let items = value.arrayValue {
                settings.projectRoots = items.compactMap { item in
                    guard let text = item.stringValue, text.hasPrefix("/") || text.hasPrefix("~/") else {
                        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an absolute or ~/ path"))
                        return nil
                    }
                    return text
                }
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an array of folder paths"))
            }
        }
        if let value = root.value(at: trustOwnOrgsPath) {
            let path = trustOwnOrgsPath.joined(separator: ".")
            if let items = value.arrayValue {
                settings.ownOrgs = items.compactMap { item in
                    guard let text = item.stringValue, !text.isEmpty else {
                        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected a non-empty GitHub user or organization name"))
                        return nil
                    }
                    return text
                }
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an array of GitHub user or organization names"))
            }
        }
        return settings
    }
}
