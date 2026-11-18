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
        plan(resources: resources, person: profiles.map { Self.personAdBlocker(profiles: $0) } ?? nil, fileExists: fileExists)
    }

    /// The plan for a `person` read ahead (`personAdBlocker(profiles:)` reads and parses each profile's
    /// preference files: a launch reads it off the main thread before the first frame, `CEFRuntime.beginLaunchPrep`).
    func plan(resources: URL?, person: Int?,
              fileExists: (String) -> Bool) -> Plan {
        guard adBlockerEnabled, person == nil, let resources else { return Plan(folders: [], keepsUnpackedEnabled: person == 4) }
        let manifest = Self.adBlockerManifest(resources: resources).path
        let folder = resources.appendingPathComponent(Self.adBlockerFolder).path
        // Chromium splits --load-extension on commas.
        guard fileExists(manifest), !folder.contains(",") else { return Plan(folders: [], keepsUnpackedEnabled: false) }
        return Plan(folders: [folder], keepsUnpackedEnabled: true)
    }

    /// The built-in uBlock Origin's manifest under the app's `resources`.
    static func adBlockerManifest(resources: URL) -> URL {
        resources.appendingPathComponent(adBlockerFolder).appendingPathComponent("manifest.json")
    }

    /// True when a Chromium profile under `profiles` holds a uBlock Origin the
    /// person installed: `extensions.settings.<id>` (Secure Preferences on
    /// macOS, or Preferences) with a path, a location Chromium loads again at
    /// start (not command line 8, not component 5 or 10), and a path that is
    /// not a cmux app's built-in folder (an installed copy has a relative path
    /// under Extensions/; a copy the person loaded unpacked, its own folder).
    static func personInstalledAdBlocker(profiles: URL, fileManager: FileManager = .default) -> Bool {
        personAdBlocker(profiles: profiles, fileManager: fileManager) != nil
    }

    /// The Chromium location of the person's uBlock Origin (4 = unpacked), or nil.
    static func personAdBlocker(profiles: URL, fileManager: FileManager = .default) -> Int? {
        guard let children = try? fileManager.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else { return nil }
        let id = Data(adBlockerID.utf8)
        for profile in children where profile.lastPathComponent.hasPrefix("Profile-") || profile.lastPathComponent == "Default" {
            for name in ["Secure Preferences", "Preferences"] {
                guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)), data.range(of: id) != nil,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any],
                      let entry = settings[adBlockerID] as? [String: Any] else { continue }
                let path = entry["path"] as? String ?? ""
                let location = (entry["location"] as? NSNumber)?.intValue ?? 0
                guard !path.isEmpty, ![5, 8, 10].contains(location), !isBuiltInPath(path) else { continue }
                // A copy below the security floor does not hold the built-in one back:
                // nothing updates it (the MV2 build is off the Web Store), so it would
                // stay exploitable. The built-in copy has the same id and storage, so
                // the person's settings and filters carry over.
                let version = personAdBlockerVersion(entry: entry, path: path, profile: profile, fileManager: fileManager)
                if let version, !isAtLeast(version, adBlockerMinimumVersion) { continue }
                return location
            }
        }
        return nil
    }

    /// The oldest uBlock Origin a person's own copy may be and still win over the
    /// built-in one. 1.75.2 and older let any website frame and drive the element
    /// picker and add trusted filters, a universal XSS (GHSA-cmqw-9r2w-6wv2, fixed
    /// in 1.75.4); 1.76.0 also validates picker filters and refuses `war:` filters.
    /// scripts/cmux-next/tests/ublock-pin.test.sh keeps the bundled pin at or above it.
    static let adBlockerMinimumVersion = "1.76.0"

    /// The version of a person's copy: the preference entry's manifest, the
    /// manifest in its folder (an unpacked copy's absolute path, or an installed
    /// copy's `<id>/<version>_0` under the profile's Extensions folder), or the
    /// installed folder's name. Nil when none says.
    static func personAdBlockerVersion(entry: [String: Any], path: String, profile: URL,
                                       fileManager: FileManager = .default) -> String? {
        if let version = (entry["manifest"] as? [String: Any])?["version"] as? String { return version }
        let folder = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : profile.appendingPathComponent("Extensions").appendingPathComponent(path)
        if let data = fileManager.contents(atPath: folder.appendingPathComponent("manifest.json").path),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = manifest["version"] as? String { return version }
        guard !path.hasPrefix("/") else { return nil }
        let name = folder.lastPathComponent
        let version = name.split(separator: "_").first.map(String.init) ?? ""
        return version.first?.isNumber == true ? version : nil
    }

    /// Dotted numeric version comparison (`1.76.4` >= `1.76.0`); a missing part is 0.
    static func isAtLeast(_ version: String, _ floor: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = floor.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// A built-in copy's recorded path: some cmux app bundle's
    /// Contents/Resources/Extensions/ublock-origin (DEV tags and releases differ).
    static func isBuiltInPath(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder) || path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder + "/")
    }

    /// SHA-256 of the staged manifest.json (scripts/cmux-next/fetch-ublock.sh
    /// UBLOCK_MANIFEST_SHA256 pins the same value; change both with a version).
    static let adBlockerManifestSHA256 = "e2736a359393899dc32875b9864e3ca4e2bd47d9011593c137bdb1314fce1d71"

    /// The running app's own built-in uBlock Origin folder (symlinks
    /// resolved) when its manifest matches the pin; nil otherwise.
    static let trustedAdBlockerFolder: String? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let folder = resources.appendingPathComponent(adBlockerFolder).resolvingSymlinksInPath().standardizedFileURL
        guard let manifest = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        return digest == adBlockerManifestSHA256 ? folder.path : nil
    }()

    /// The cmux-shipped uBlock Origin: its id, loaded from exactly this app's
    /// pinned built-in folder. A copy the person installed or loaded (another
    /// path) and every other extension are not.
    static func isTrustedBuiltIn(_ info: BrowserExtensionInfo, trustedFolder: String? = trustedAdBlockerFolder) -> Bool {
        guard info.id == adBlockerID, let trustedFolder, !info.path.isEmpty else { return false }
        return URL(fileURLWithPath: info.path).resolvingSymlinksInPath().standardizedFileURL.path == trustedFolder
    }
}
