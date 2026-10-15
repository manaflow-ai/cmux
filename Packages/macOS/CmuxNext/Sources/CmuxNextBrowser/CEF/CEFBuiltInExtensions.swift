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

    /// The folders to load: the bundled uBlock Origin when it is on and the
    /// bundle carries it (a build without network may lack it).
    func folders(resources: URL?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        guard adBlockerEnabled, let resources else { return [] }
        let manifest = resources.appendingPathComponent(Self.adBlockerFolder).appendingPathComponent("manifest.json").path
        let folder = resources.appendingPathComponent(Self.adBlockerFolder).path
        // Chromium splits --load-extension on commas.
        guard fileExists(manifest), !folder.contains(",") else { return [] }
        return [folder]
    }
}
