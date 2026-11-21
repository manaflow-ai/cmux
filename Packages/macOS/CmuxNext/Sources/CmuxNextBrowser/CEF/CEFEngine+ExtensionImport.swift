import CmuxNextBrowserCore
public import Foundation

/// Browser import: the extensions of another browser into a cmux profile, named by its wire id
/// (`BrowserProfileRecord`). Web Store ones are installed from their store page (the store's own
/// Add button); unpacked ones are copied by the import and loaded here (`cmux_shim_ext_load_unpacked`).
extension CEFEngine {
    /// The profile's Chromium folder, whose `Preferences` list what it has installed, and the
    /// folder the import copies its unpacked extensions to (`<id>` folders, beside the Chromium
    /// root, never inside a profile Chromium owns). Nil for an id that is not a browser profile.
    public func importedExtensionFolders(forProfile wireID: String) -> (profile: URL, copies: URL)? {
        guard let profile = BrowserProfileRecord.engineProfile(for: wireID) else { return nil }
        let storage = CEFRuntime.shared.storage
        let copies = storage.root.deletingLastPathComponent()
            .appending(path: "Imported Extensions", directoryHint: .isDirectory)
            .appending(path: "Profile-" + profile.rawValue.uuidString, directoryHint: .isDirectory)
        return (storage.cachePath(for: profile), copies)
    }

    /// Loads the copied unpacked `folders` into the profile, now when a Chromium page of it is
    /// open or when the first one opens.
    public func loadImportedUnpacked(_ folders: [String], intoProfile wireID: String) {
        guard let profile = BrowserProfileRecord.engineProfile(for: wireID) else { return }
        CEFRuntime.shared.extensionStores.loadUnpacked(folders, into: profile)
    }
}
