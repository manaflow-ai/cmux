public import Foundation

/// Removes a deleted browser profile's Chromium data: its `Profile-<UUID>`
/// directory and every remote-localhost derived store `Profile-<UUID>-m-*`
/// (plans/cmux-next/data-model.md section 5). Run it only while Chromium has
/// not loaded that profile in this process (at launch, before CEF starts,
/// or for a profile no Chromium page used). WebKit data goes through
/// `WebKitProfileStore.removeData`.
public nonisolated struct BrowserProfileStorageCleanup: Sendable {
    public let chromiumRoot: URL

    public init(chromiumRoot: URL) {
        self.chromiumRoot = chromiumRoot
    }

    /// Directory names of `id`'s Chromium stores among `names`.
    public static func chromiumDirectories(for id: String, in names: [String]) -> [String] {
        guard id != BrowserProfileRecord.defaultID, let profile = BrowserProfileRecord.engineProfile(for: id) else { return [] }
        let base = "Profile-" + profile.rawValue.uuidString
        return names.filter { $0 == base || $0.hasPrefix(base + "-m-") }
    }

    /// Removes the Chromium stores of `ids`; returns the ids whose data is
    /// gone (nothing left to remove). `default` and invalid ids are skipped.
    @discardableResult
    public func removeChromiumData(for ids: [String]) -> [String] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: chromiumRoot.path)) ?? []
        var removed: [String] = []
        for id in ids where id != BrowserProfileRecord.defaultID && BrowserProfileRecord.engineProfile(for: id) != nil {
            var failed = false
            for name in Self.chromiumDirectories(for: id, in: names) {
                do { try manager.removeItem(at: chromiumRoot.appending(path: name)) } catch { failed = true }
            }
            if !failed { removed.append(id) }
        }
        return removed
    }
}
