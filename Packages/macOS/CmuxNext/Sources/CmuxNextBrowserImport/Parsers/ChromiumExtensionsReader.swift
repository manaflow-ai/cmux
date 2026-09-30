public import Foundation

/// Lists the Chrome Web Store extensions of a Chromium profile.
///
/// Sources, merged per id: `Secure Preferences` and `Preferences`
/// (`extensions.settings.<id>`: location, from_webstore, state,
/// was_installed_by_default) and the unpacked copies under
/// `Extensions/<id>/<version>/manifest.json` (name, resolving `__MSG_x__`
/// through `_locales/<default_locale>/messages.json`). Component, policy,
/// default-installed and unpacked extensions are left out: they cannot be
/// reinstalled from the store.
public enum ChromiumExtensionsReader {
    /// Chrome's own apps that ship with every profile.
    static let builtIns: Set<String> = [
        "nmmhkkegccagdldgiimedpiccmgmieda",  // Chrome Web Store Payments
        "pjkljhegncpnkpknbcohdijeoejaedia",  // Gmail (legacy app)
        "blpcfgokakmgnkcojhhkbfbldkacnbeo",  // YouTube (legacy app)
        "apdfllckaahabafndbhieahigkjlhalf",  // Google Drive (legacy app)
        "aapocclcgogkmnckokdopfmhonfmgoek",  // Slides
        "aohghmighlieiainnegkcijnfilokake",  // Docs
        "felcaaldnbdncclmgdcncolpebgiejap",  // Sheets
        "ahfgeienlihckogmohjhadlkjgocpleb",  // Web Store app
    ]

    /// Chromium `Manifest::Location` values that can come from the store:
    /// INTERNAL (1), EXTERNAL_PREF_DOWNLOAD (6), EXTERNAL_POLICY_DOWNLOAD is
    /// policy (7, excluded).
    static let storeLocations: Set<Int> = [1, 6]

    public static func read(profile: URL) -> [ImportedExtension] {
        var settings: [String: [String: Any]] = [:]
        for name in ["Preferences", "Secure Preferences"] {
            guard let data = try? Data(contentsOf: profile.appending(path: name)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let extensions = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
            for (id, value) in extensions {
                guard let entry = value as? [String: Any] else { continue }
                settings[id, default: [:]].merge(entry) { _, new in new }
            }
        }
        let installed = profile.appending(path: "Extensions")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: installed.path)) ?? []
        let ids = Set(settings.keys).union(folders).filter(ImportedExtension.isValidID).subtracting(builtIns)
        return ids.compactMap { id -> ImportedExtension? in
            let entry = settings[id] ?? [:]
            if let location = entry["location"] as? Int, !storeLocations.contains(location) { return nil }
            if entry["was_installed_by_default"] as? Bool == true || entry["was_installed_by_oem"] as? Bool == true { return nil }
            let manifest = latestManifest(installed.appending(path: id))
            let prefManifest = entry["manifest"] as? [String: Any]
            guard let name = displayName(manifest, prefManifest) else { return nil }
            if (manifest?.json["theme"] ?? prefManifest?["theme"]) != nil { return nil }  // Themes are not extensions.
            let fromStore = entry["from_webstore"] as? Bool ?? (manifest?.json["update_url"] as? String)?.contains("google.com") ?? true
            let state = entry["state"] as? Int
            let disabled = state == 0 || ((entry["disable_reasons"] as? Int) ?? 0) != 0
            return ImportedExtension(id: id, name: name, version: manifest?.json["version"] as? String ?? prefManifest?["version"] as? String,
                                     enabled: !disabled, fromWebStore: fromStore)
        }
        .filter(\.fromWebStore)
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    struct Manifest {
        var json: [String: Any]
        var folder: URL
    }

    /// The manifest in the highest version folder.
    static func latestManifest(_ extensionFolder: URL) -> Manifest? {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: extensionFolder.path)) ?? []
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in sorted {
            let folder = extensionFolder.appending(path: version, directoryHint: .isDirectory)
            if let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return Manifest(json: json, folder: folder)
            }
        }
        return nil
    }

    static func displayName(_ manifest: Manifest?, _ prefManifest: [String: Any]?) -> String? {
        let raw = (manifest?.json["name"] ?? prefManifest?["name"]) as? String
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), let manifest else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        let locales = [manifest.json["default_locale"] as? String, "en", "en_US"].compactMap { $0 }
        for locale in locales {
            let file = manifest.folder.appending(path: "_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Message keys are case-insensitive.
            if let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return nil
    }
}
