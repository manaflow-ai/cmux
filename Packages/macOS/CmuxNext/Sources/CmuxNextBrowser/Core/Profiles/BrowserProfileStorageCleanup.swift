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
        [] // stub
    }

    /// Removes the Chromium stores of `ids`; returns the ids whose data is
    /// gone (nothing left to remove). `default` and invalid ids are skipped.
    @discardableResult
    public func removeChromiumData(for ids: [String]) -> [String] {
        [] // stub
    }
}
