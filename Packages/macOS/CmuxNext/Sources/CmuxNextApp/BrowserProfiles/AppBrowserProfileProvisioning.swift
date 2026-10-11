import CmuxNextBrowser
import CmuxNextBrowserImport

/// Each imported browser profile becomes a cmux browser profile with the
/// id the importer proposed (a retry finds the same record) and the
/// source's name (data-model.md 5).
struct AppBrowserProfileProvisioning: BrowserProfileProvisioning {
    let profiles: BrowserProfileService

    func createProfile(id: String, name: String, color: String?, source: [String: String]) async throws -> String {
        try await profiles.createProfile(id: id, name: name, color: color, icon: nil, source: source)
    }
}
