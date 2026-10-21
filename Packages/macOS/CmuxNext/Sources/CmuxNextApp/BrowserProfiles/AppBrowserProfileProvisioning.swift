import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign

/// Each imported browser profile becomes a cmux browser profile with the
/// id the importer proposed (a retry finds the same record) and the
/// source's name, nearest group color and picture (data-model.md 5); one an
/// earlier import made keeps the look the person gave it since.
struct AppBrowserProfileProvisioning: BrowserProfileProvisioning {
    let profiles: BrowserProfileService

    func createProfile(id: String, name: String, look: SourceProfileLook, source: [String: String]) async throws -> String {
        let fresh = await profiles.record(id) == nil
        // Browser profiles live in the local daemon, which stores their image icons.
        let png = fresh ? await Task.detached { look.avatarPNG() }.value : nil
        let icon = if let png { try? await IconAssetStore.owner(profiles.services.machines.local)?.put("image/png", png) } else { String?.none }
        return try await profiles.createProfile(id: id, name: name, color: fresh ? look.color.map { GroupColor.nearest(rgb: $0).rawValue } : nil,
                                                icon: icon, source: source)
    }
}
