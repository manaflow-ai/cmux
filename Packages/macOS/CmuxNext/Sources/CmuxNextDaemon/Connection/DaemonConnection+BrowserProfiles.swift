public import Foundation

/// Browser profile records in the home session (`browser-profiles-v1`).
/// Each wrapper throws `missingCapabilities` on a daemon without it.
extension DaemonConnection {
    public var supportsBrowserProfiles: Bool { identity?.supports(DaemonCapabilities.shared.browserProfiles) == true }

    private func requireBrowserProfiles() throws {
        guard supportsBrowserProfiles else { throw DaemonError.missingCapabilities([DaemonCapabilities.shared.browserProfiles]) }
    }

    @discardableResult
    public func createBrowserProfile(_ request: CreateBrowserProfileRequest) async throws -> BrowserProfileResult {
        try requireBrowserProfiles()
        return try await self.request(request)
    }

    @discardableResult
    public func updateBrowserProfile(_ request: UpdateBrowserProfileRequest) async throws -> BrowserProfileResult {
        try requireBrowserProfiles()
        return try await self.request(request)
    }

    public func moveBrowserProfile(_ id: String, to index: Int) async throws {
        try requireBrowserProfiles()
        _ = try await request(MoveBrowserProfileRequest(id: id, index: index))
    }

    public func deleteBrowserProfile(_ id: String) async throws {
        try requireBrowserProfiles()
        _ = try await request(DeleteBrowserProfileRequest(id: id))
    }
}
