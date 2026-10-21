import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation

/// Each imported browser profile becomes a cmux browser profile with the
/// id the importer proposed (a retry finds the same record), the source's
/// name, the group color nearest its color and its account picture as the
/// icon (data-model.md 5). A profile made by an earlier import keeps
/// whatever look the person gave it since.
struct AppBrowserProfileProvisioning: BrowserProfileProvisioning {
    let profiles: BrowserProfileService

    func createProfile(id: String, name: String, look: SourceProfileLook, source: [String: String]) async throws -> String {
        if await profiles.record(id) != nil {
            return try await profiles.createProfile(id: id, name: name, color: nil, icon: nil, source: source)
        }
        let color = look.color.map { GroupColor.nearest(rgb: $0).rawValue }
        let icon = await Self.icon(look.avatar, assets: assets())
        return try await profiles.createProfile(id: id, name: name, color: color, icon: icon, source: source)
    }

    /// Browser profiles live in the local daemon, which stores their image icons.
    @MainActor private func assets() -> IconAssetStore? { IconAssetStore.owner(profiles.services.machines.local) }

    /// The source's account picture stored as an image icon; nil when it has
    /// none, the file is not an image, or the daemon has no icon store.
    private static func icon(_ avatar: URL?, assets: IconAssetStore?) async -> String? {
        guard let avatar, let assets else { return nil }
        let prepared = await Task.detached { () -> (mediaType: String, data: Data)? in
            guard let data = try? Data(contentsOf: avatar, options: .mappedIfSafe), data.count <= IconAssetKind.maxImageDownloadBytes else { return nil }
            return IconAssetKind.image.prepare(downloaded: data)
        }.value
        guard let prepared else { return nil }
        return try? await assets.put(prepared.mediaType, prepared.data)
    }
}
