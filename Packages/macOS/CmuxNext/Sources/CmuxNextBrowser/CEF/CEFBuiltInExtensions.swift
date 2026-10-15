import Foundation

/// Extensions that ship inside the app bundle and load into Chromium at its
/// start: today the full uBlock Origin (Manifest V2, GPL-3.0), staged by
/// scripts/cmux-next/bundle-ublock.sh into Contents/Resources/Extensions/.
/// They load through `--load-extension` like a development extension, but do
/// not turn on the extensions developer mode. Its manifest carries the Chrome
/// Web Store key, so its id (and the person's uBlock Origin settings) stays
/// the same across versions and matches a copy imported from Chrome.
nonisolated struct CEFBuiltInExtensions: Equatable, Sendable {
    /// The built-in uBlock Origin's extension id (the Chrome Web Store id).
    static let adBlockerID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
    static let adBlockerFolder = "Extensions/ublock-origin"

    /// `browser.builtInAdBlocker` (on unless the person turned it off).
    var adBlockerEnabled: Bool

    /// The folders to load: the bundled uBlock Origin when it is on, the
    /// bundle carries it (a build without network may lack it), and no
    /// profile under `profiles` holds a uBlock Origin the person installed.
    /// That copy has the same id; a --load-extension copy would replace it,
    /// and turning the setting off would then drop it. The person's copy wins.
    func folders(resources: URL?, profiles: URL? = nil,
                 fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard adBlockerEnabled, let resources else { return [] }
        let manifest = resources.appendingPathComponent(Self.adBlockerFolder).appendingPathComponent("manifest.json").path
        let folder = resources.appendingPathComponent(Self.adBlockerFolder).path
        // Chromium splits --load-extension on commas.
        guard fileExists(manifest), !folder.contains(",") else { return [] }
        if let profiles, Self.personInstalledAdBlocker(profiles: profiles) { return [] }
        return [folder]
    }

    /// True when a Chromium profile under `profiles` holds a uBlock Origin the
    /// person installed: `extensions.settings.<id>` (Secure Preferences on
    /// macOS, or Preferences) with a path, a location Chromium loads again at
    /// start (not command line 8, not component 5 or 10), and a path that is
    /// not a cmux app's built-in folder (an installed copy has a relative path
    /// under Extensions/; a copy the person loaded unpacked, its own folder).
    static func personInstalledAdBlocker(profiles: URL, fileManager: FileManager = .default) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else { return false }
        let id = Data(adBlockerID.utf8)
        for profile in children where profile.lastPathComponent.hasPrefix("Profile-") || profile.lastPathComponent == "Default" {
            for name in ["Secure Preferences", "Preferences"] {
                guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)), data.range(of: id) != nil,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any],
                      let entry = settings[adBlockerID] as? [String: Any] else { continue }
                let path = entry["path"] as? String ?? ""
                let location = (entry["location"] as? NSNumber)?.intValue ?? 0
                if !path.isEmpty, ![5, 8, 10].contains(location), !isBuiltInPath(path) { return true }
            }
        }
        return false
    }

    /// A built-in copy's recorded path: some cmux app bundle's
    /// Contents/Resources/Extensions/ublock-origin (DEV tags and releases differ).
    static func isBuiltInPath(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder) || path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder + "/")
    }
}
