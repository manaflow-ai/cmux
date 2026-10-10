public import Foundation

/// One cookie backup an agent's clear left on this Mac (decision D3 on
/// issue 13742: the person lists and deletes them on the History page).
/// No cookie value ever reaches the page.
public nonisolated struct HistoryCookieBackup: Identifiable, Hashable, Sendable {
    /// The restore id (`app:<32 hex>`).
    public let id: String
    /// The host whose cookies the clear removed.
    public let site: String
    public let createdAt: Date

    public init(id: String, site: String, createdAt: Date) {
        self.id = id
        self.site = site
        self.createdAt = createdAt
    }
}

public extension HistoryPageSource {
    /// An App with no cookie backups.
    func cookieBackups() async -> [HistoryCookieBackup] { [] }
    func deleteCookieBackups(_ ids: [String]) async {}
}

public extension HistoryPageModel {
    /// Shows the cookie backups sheet and loads its rows.
    func showCookieBackups() {
        showsCookieBackups = true
        loadCookieBackups()
    }

    func loadCookieBackups() {
        Task { [weak self] in
            let loaded = await self?.source?.cookieBackups() ?? []
            self?.cookieBackups = loaded
        }
    }

    /// Deletes backups for good (the person confirmed): an agent can no
    /// longer undo those clears.
    func deleteCookieBackups(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        cookieBackups.removeAll { ids.contains($0.id) }
        Task { [weak self] in
            await self?.source?.deleteCookieBackups(ids)
            self?.loadCookieBackups()
        }
    }
}
