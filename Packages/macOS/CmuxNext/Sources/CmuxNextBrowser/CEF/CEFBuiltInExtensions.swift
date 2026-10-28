import CmuxNextCompat
import CryptoKit
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
        plan(resources: resources, profiles: profiles, fileExists: fileExists).folders
    }

    /// What Chromium starts with: the folders to load, and whether unpacked
    /// extensions stay enabled without developer mode (the built-in copy
    /// loads, or the person has their own unpacked copy of it).
    struct Plan: Equatable, Sendable {
        var folders: [String]
        var keepsUnpackedEnabled: Bool
    }

    func plan(resources: URL?, profiles: URL?,
              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Plan {
        let person = profiles.map { Self.personAdBlocker(profiles: $0) } ?? nil
        guard adBlockerEnabled, person == nil, let resources else { return Plan(folders: [], keepsUnpackedEnabled: person == 4) }
        let manifest = resources.appendingPathComponent(Self.adBlockerFolder).appendingPathComponent("manifest.json").path
        let folder = resources.appendingPathComponent(Self.adBlockerFolder).path
        // Chromium splits --load-extension on commas.
        guard fileExists(manifest), !folder.contains(",") else { return Plan(folders: [], keepsUnpackedEnabled: false) }
        return Plan(folders: [folder], keepsUnpackedEnabled: true)
    }

    /// True when a Chromium profile under `profiles` holds a uBlock Origin the
    /// person installed: `extensions.settings.<id>` (Secure Preferences on
    /// macOS, or Preferences) with a path, a location Chromium loads again at
    /// start (not command line 8, not component 5 or 10), and a path that is
    /// not a cmux app's built-in folder (an installed copy has a relative path
    /// under Extensions/; a copy the person loaded unpacked, its own folder).
    static func personInstalledAdBlocker(profiles: URL) -> Bool {
        personAdBlocker(profiles: profiles) != nil
    }

    /// The Chromium location of the person's uBlock Origin (4 = unpacked), or nil.
    static func personAdBlocker(profiles: URL) -> Int? {
        guard let children = try? FileManager.checked.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else { return nil }
        let id = Data(adBlockerID.utf8)
        for profile in children where profile.lastPathComponent.hasPrefix("Profile-") || profile.lastPathComponent == "Default" {
            for name in ["Secure Preferences", "Preferences"] {
                guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)), data.range(of: id) != nil,
                      let root = try? JSONSerialization.blockingJSONObject(with: data) as? [String: Any],
                      let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any],
                      let entry = settings[adBlockerID] as? [String: Any] else { continue }
                let path = entry["path"] as? String ?? ""
                let location = (entry["location"] as? NSNumber)?.intValue ?? 0
                if !path.isEmpty, ![5, 8, 10].contains(location), !isBuiltInPath(path) { return location }
            }
        }
        return nil
    }

    /// A built-in copy's recorded path: some cmux app bundle's
    /// Contents/Resources/Extensions/ublock-origin (DEV tags and releases differ).
    static func isBuiltInPath(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder) || path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder + "/")
    }

    /// SHA-256 of the staged manifest.json (scripts/cmux-next/fetch-ublock.sh
    /// UBLOCK_MANIFEST_SHA256 pins the same value; change both with a version).
    static let adBlockerManifestSHA256 = "8736fdbd889f05a37c62b98da88ad3e9e2ae72a067f0909e18bc051792ab161d"

    /// The built-in uBlock Origin folder under `resources` (the running app's
    /// Contents/Resources; symlinks resolved) when its manifest matches the
    /// pin; nil otherwise. Reads the manifest: the extension access owner
    /// preloads it once on the files lane
    /// (``AgentExtensionAccess/readTrustedBuiltInFolder(resources:)``), never
    /// from a static initializer on whichever thread asks first (p02-threads-122).
    static func trustedAdBlockerFolder(resources: URL?) -> String? {
        guard let resources else { return nil }
        let folder = resources.appendingPathComponent(adBlockerFolder).resolvingSymlinksInPath().standardizedFileURL
        guard let manifest = try? Data(blockingContentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        return digest == adBlockerManifestSHA256 ? folder.path : nil
    }

    /// The cmux-shipped uBlock Origin: its id, loaded from exactly this app's
    /// pinned built-in folder (``trustedAdBlockerFolder(resources:)``). A copy
    /// the person installed or loaded (another path) and every other extension
    /// are not.
    static func isTrustedBuiltIn(_ info: BrowserExtensionInfo, trustedFolder: String?) -> Bool {
        guard info.id == adBlockerID, let trustedFolder, !info.path.isEmpty else { return false }
        return URL(fileURLWithPath: info.path).resolvingSymlinksInPath().standardizedFileURL.path == trustedFolder
    }
}
