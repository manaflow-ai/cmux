#if DEBUG || CMUX_BENCH_HOOKS
import CryptoKit
import Foundation

/// What the refactor oracle's `settings` facet records of an applied snapshot: values only,
/// no file read. Chromium's `chrome://prefs-internals` does the same: it serializes the values `PrefService`
/// holds in memory, never the Preferences file, and a pref is non-default by comparison with its registered
/// default (components/prefs/pref_service.cc, `PrefService::GetPreferenceValues`, `Preference::IsDefaultValue`).
extension CmuxConfigSnapshot {
    /// `sha256:<hex>` of the effective document (file, MDM and team layers) as canonical JSON: keys sorted, no
    /// whitespace (``JSONValue/compactText``), the form the oracle runner hashes
    /// (scripts/cmux-next/oracle/normalize.py, `canonical_json`). Private text in the document (custom
    /// commands, hosts) reaches the oracle only through this hash.
    public var effectiveSha256: String {
        "sha256:" + SHA256.hash(data: Data(root.compactText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The dotted id of each `catalog` setting the effective document sets to a value other than its default,
    /// sorted: the rows Settings shows Reset on (``SettingDescriptor/isCustomized(in:)``, which reads a renamed
    /// key's old key as the parser does). A setting whose default is derived at run time (no `defaultValue`)
    /// counts whenever it is set. Keys outside the catalog (shortcut bindings, custom actions) are user-named,
    /// so only ``effectiveSha256`` records them.
    public func nonDefaultKeys(in catalog: [SettingDescriptor] = SettingsSchema.all) -> [String] {
        Set(catalog.filter { $0.isCustomized(in: root) }.map(\.id)).sorted()
    }
}
#endif
