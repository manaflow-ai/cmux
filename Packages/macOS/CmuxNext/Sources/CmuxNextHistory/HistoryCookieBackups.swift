public import Foundation

/// One cookie backup an agent's clear left on this Mac (decision D3 on
/// issue 13742: the person lists and deletes them on the History page).
/// No cookie value ever reaches the page.
public nonisolated struct HistoryCookieBackup: Identifiable, Hashable, Sendable {
    /// The restore id (`app:<32 hex>`).
    public let id: String
    /// The host whose cookies the clear removed; nil when the backup no
    /// longer opens with this Mac's key (the person can still delete it).
    public let site: String?
    public let createdAt: Date

    public init(id: String, site: String?, createdAt: Date) {
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
        Task { await refreshCookieBackups() }
    }

    /// Loads the rows; a load that an older call started never replaces a
    /// newer one (a delete starts a new load).
    @discardableResult
    func refreshCookieBackups() async -> [HistoryCookieBackup] {
        cookieBackupsGeneration += 1
        let current = cookieBackupsGeneration
        let loaded = await source?.cookieBackups() ?? []
        if current == cookieBackupsGeneration { cookieBackups = loaded }
        return loaded
    }

    /// Deletes backups for good (the person confirmed): an agent can no
    /// longer undo those clears.
    func deleteCookieBackups(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        cookieBackups.removeAll { ids.contains($0.id) }
        cookieBackupsGeneration += 1
        Task { await deleteCookieBackupsNow(ids) }
    }

    /// ``deleteCookieBackups(_:)``, awaited (the debug control method waits for it).
    func deleteCookieBackupsNow(_ ids: [String]) async {
        await source?.deleteCookieBackups(ids)
        await refreshCookieBackups()
    }
}
