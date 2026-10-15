public import Foundation

/// Extensions that ship inside the app bundle and load into Chromium at its
/// start: the full uBlock Origin (Manifest V2, GPL-3.0) under
/// `Contents/Resources/Extensions/ublock-origin`.
///
/// They load through `--load-extension` like a development extension but do
/// not turn on developer mode. The manifest carries the Chrome Web Store key,
/// so the id (and the person's uBlock Origin settings) stays the same across
/// versions and matches a copy imported from Chrome.
///
/// In cmux Classic the built-in ad blocker is off by default (setting
/// `browser.chromium.builtInAdBlocker`); turning it on by default is a policy
/// decision tracked on the trust-policy issue.
public struct BrowserBuiltInExtensions: Equatable, Sendable {
    /// The built-in uBlock Origin's extension id (the Chrome Web Store id).
    public static let adBlockerID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
    /// The bundled folder, relative to the app's resources.
    public static let adBlockerFolder = "Extensions/ublock-origin"
    /// SHA-256 of the staged manifest.json; the fetch script pins the same value.
    public static let adBlockerManifestSHA256 = "8736fdbd889f05a37c62b98da88ad3e9e2ae72a067f0909e18bc051792ab161d"

    /// What Chromium starts with.
    public struct Plan: Equatable, Sendable {
        /// The extension folders to pass to `--load-extension`.
        public var folders: [String]
        /// True when unpacked extensions stay enabled without developer mode
        /// (the built-in copy loads, or the person has their own unpacked copy of it).
        public var keepsUnpackedEnabled: Bool

        /// Creates a plan.
        public init(folders: [String], keepsUnpackedEnabled: Bool) {
            self.folders = folders
            self.keepsUnpackedEnabled = keepsUnpackedEnabled
        }
    }

    /// True when the person turned the built-in ad blocker on.
    public var adBlockerEnabled: Bool

    /// Creates the built-in extension rules.
    ///
    /// - Parameter adBlockerEnabled: The `browser.chromium.builtInAdBlocker` setting.
    public init(adBlockerEnabled: Bool) {
        self.adBlockerEnabled = adBlockerEnabled
    }

    /// The folders to load and the developer-mode rule.
    ///
    /// Loads the bundled uBlock Origin only when it is on, the bundle carries
    /// it, and no profile under `profiles` holds a uBlock Origin the person
    /// installed. That copy has the same id; a `--load-extension` copy would
    /// replace it, and turning the setting off would then drop it. The
    /// person's copy wins.
    ///
    /// - Parameters:
    ///   - resources: The app's resources folder.
    ///   - profiles: The Chromium profiles root, when known.
    ///   - fileExists: File existence check (injected for tests).
    /// - Returns: The start plan.
    public func plan(resources: URL?, profiles: URL?,
                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Plan {
        let person = profiles.flatMap { Self.personAdBlockerLocation(profiles: $0) }
        guard adBlockerEnabled, person == nil, let resources else {
            return Plan(folders: [], keepsUnpackedEnabled: person == Self.unpackedLocation)
        }
        let folderURL = resources.appendingPathComponent(Self.adBlockerFolder)
        let manifest = folderURL.appendingPathComponent("manifest.json").path
        // Chromium splits --load-extension on commas.
        guard fileExists(manifest), !folderURL.path.contains(",") else {
            return Plan(folders: [], keepsUnpackedEnabled: false)
        }
        return Plan(folders: [folderURL.path], keepsUnpackedEnabled: true)
    }

    /// Chromium's `ManifestLocation::kUnpacked`.
    static let unpackedLocation = 4

    /// The Chromium location of a uBlock Origin the person installed, or nil.
    ///
    /// Reads `extensions.settings.<id>` from each profile's `Secure Preferences`
    /// or `Preferences`. Counts a copy with a path, a location Chromium loads
    /// again at start (not component 5/10 or command line 8), and a path that
    /// is not some cmux app's built-in folder.
    ///
    /// - Parameters:
    ///   - profiles: The Chromium profiles root.
    ///   - fileManager: The file manager (injected for tests).
    /// - Returns: The location (4 = unpacked), or nil.
    public static func personAdBlockerLocation(profiles: URL, fileManager: FileManager = .default) -> Int? {
        guard let children = try? fileManager.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else {
            return nil
        }
        let id = Data(adBlockerID.utf8)
        for profile in children where profile.lastPathComponent.hasPrefix("Profile-")
            || profile.lastPathComponent == "Default" {
            for name in ["Secure Preferences", "Preferences"] {
                guard let data = fileManager.contents(atPath: profile.appendingPathComponent(name).path),
                      data.range(of: id) != nil,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any],
                      let entry = settings[adBlockerID] as? [String: Any] else { continue }
                let path = entry["path"] as? String ?? ""
                let location = (entry["location"] as? NSNumber)?.intValue ?? 0
                if !path.isEmpty, ![5, 8, 10].contains(location), !isBuiltInPath(path) { return location }
            }
        }
        return nil
    }

    /// True for a built-in copy's recorded path: some cmux app bundle's
    /// `Contents/Resources/Extensions/ublock-origin` (tagged builds and releases differ).
    public static func isBuiltInPath(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder)
            || path.hasSuffix(".app/Contents/Resources/" + adBlockerFolder + "/")
    }

    /// True for the cmux-shipped uBlock Origin: its id, loaded from exactly
    /// `trustedFolder`. A copy the person installed or loaded elsewhere, and
    /// every other extension, are not.
    ///
    /// - Parameters:
    ///   - info: The extension.
    ///   - trustedFolder: This app's pinned built-in folder (see ``BrowserBuiltInExtensionTrust``), or nil.
    public static func isTrustedBuiltIn(_ info: BrowserExtensionInfo, trustedFolder: String?) -> Bool {
        guard info.id == adBlockerID, let trustedFolder, !info.path.isEmpty else { return false }
        return URL(fileURLWithPath: info.path).resolvingSymlinksInPath().standardizedFileURL.path == trustedFolder
    }
}
