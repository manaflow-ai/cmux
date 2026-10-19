import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
public import CmuxNextHistory
import Foundation

/// Stash (a native OneTab, `stash-v1`) on this Mac's daemon: serves the Stashed page
/// (``StashPageSource``). The page's model is the one list every surface reads; it lists the
/// stashes again on each stash change the daemon publishes on `session.events` (the CLI, MCP,
/// another window).
public final class StashService: StashPageSource {
    private weak var host: (any StashHost)?
    public let model = StashPageModel()
    /// Each Stashed page's own OneTab paste box, by page key.
    private var drafts: [String: StashImportDraft] = [:]

    /// Creates the service over `host`'s daemon and starts following its stash changes.
    /// - Parameter host: The App's side of Stash; held weakly.
    public init(host: any StashHost) {
        self.host = host
        model.source = self
        watchChanges()
    }

    /// Lists the stashes again once this Mac's daemon serves them, and on each stash change it
    /// publishes (`SessionStateStore.stashChanges`).
    private func watchChanges() {
        // task-owner: lives as long as the service; ends when it or its host goes.
        Task { [weak self] in
            var last: Int?
            let changes = ObservationStream { [weak self] () -> Int? in
                guard let self, let daemon = self.host?.localDaemon, self.serves(daemon) else { return nil }
                return daemon.store.session.stashChanges
            }
            for await change in changes where change != last {
                last = change
                guard let self else { return }
                if change != nil { await self.model.reload() }
            }
        }
    }

    /// The OneTab paste box of the Stashed page `key`, made on first use.
    public func draft(for key: String) -> StashImportDraft {
        if let draft = drafts[key] { return draft }
        let draft = StashImportDraft()
        drafts[key] = draft
        return draft
    }

    /// Forgets the paste box of the Stashed page `key` once its tab closed.
    public func dropDraft(_ key: String) { drafts[key] = nil }

    /// Whether `daemon` keeps stashes; without it no stash UI shows. Only this Mac's daemon.
    func serves(_ daemon: DaemonService) -> Bool { daemon.isLocal && daemon.supports(DaemonCapabilities.shared.stash) }

    /// This Mac's daemon's state client, when it keeps stashes.
    private func state() throws -> StateResourceClient {
        guard let daemon = host?.localDaemon else { throw ActionFailure(message: RefusalStrings.daemonConnecting) }
        guard let connection = daemon.connection else {
            throw ActionFailure(message: daemon.notConnectedReason ?? RefusalStrings.daemonConnecting)
        }
        guard serves(daemon) else { throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapabilities.shared.stash)) }
        return connection.state
    }

    /// `error` as the user-facing reason the page shows.
    private static func failure(_ error: any Error) -> any Error {
        error is ActionFailure ? error : ActionFailure(message: RefusalStrings.describe(error))
    }

    // MARK: StashPageSource

    public func stashes() async throws -> [StashedGroup] {
        let records: [StashRecord]
        do { records = try await state().stashes() } catch { throw Self.failure(error) }
        return records.map { record in
            StashedGroup(id: record.id, name: record.name, createdAt: Date(timeIntervalSince1970: Double(record.createdAtMs) / 1000),
                         tabs: record.members.map { StashedGroup.Tab(id: $0.id, url: $0.url, title: $0.title, profile: $0.browserProfileID) })
        }
    }

    /// `here` puts a page whose pane is gone in the active window's focused pane; the restored
    /// pages are shown (their workspace in the active window, the first one selected).
    public func restore(_ group: StashedGroup, tabs: [StashedGroup.Tab], inNewWorkspace: Bool) async throws {
        do {
            let state = try state()
            let reopened = try await state.restoreStash(group.id, members: tabs.map(\.id), target: inNewWorkspace ? .newWorkspace : .here,
                                                        pane: host?.stashRestorePane)
            guard let host, let connection = host.localDaemon.connection else { return }
            await host.localDaemon.store.applied(through: await connection.eventSequence())
            host.showRestored(reopened, asWorkspace: inNewWorkspace)
        } catch { throw Self.failure(error) }
    }

    public func delete(_ group: StashedGroup, tabs: [StashedGroup.Tab]?) async throws {
        do { try await state().deleteStash(group.id, members: tabs?.map(\.id)) } catch { throw Self.failure(error) }
    }

    /// Imported pages reopen in the app's browser engine (`browser.defaultEngine`, WebKit without Chromium).
    public func importGroups(_ groups: [OneTabExport.Group]) async throws -> (imported: Int, skipped: Int) {
        let wire = groups.map { group in
            StateResourceClient.StashImportGroup(name: nil, pages: group.tabs.map { .init(url: $0.url, title: $0.title) })
        }
        do {
            let result = try await state().importOneTab(wire, engine: host?.stashImportEngine ?? BrowserEngine.webkit.rawValue)
            return (result.importedTabs, result.skippedTabs)
        } catch { throw Self.failure(error) }
    }
}
