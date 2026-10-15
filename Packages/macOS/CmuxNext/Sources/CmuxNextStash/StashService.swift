public import CmuxNextActions
import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextHistory
import Foundation

/// Stash (a native OneTab, `stash-v1`) on this Mac's daemon: serves the Stashed page
/// (`StashPageSource`) and closes tabs into stashes for the Stash actions. The page's model is
/// the one list every surface reads.
public final class StashService: StashPageSource {
    private weak var host: (any StashHost)?
    public let model = StashPageModel()
    /// Each Stashed page's own OneTab paste box, by page key.
    private var drafts: [String: StashImportDraft] = [:]

    public init(host: any StashHost) {
        self.host = host
        model.source = self
    }

    public func draft(for key: String) -> StashImportDraft {
        if let draft = drafts[key] { return draft }
        let draft = StashImportDraft()
        drafts[key] = draft
        return draft
    }

    public func dropDraft(_ key: String) { drafts[key] = nil }

    /// Whether `daemon` keeps stashes; without it no stash UI shows. Only this Mac's daemon.
    public func serves(_ daemon: DaemonService) -> Bool { daemon.isLocal && daemon.supports(DaemonCapabilities.shared.stash) }

    /// The reason stash actions are unavailable, or nil while this Mac's daemon keeps stashes.
    func unavailableReason() -> String? {
        guard let daemon = host?.localDaemon, !serves(daemon) else { return nil }
        return daemon.missingCapabilityMessage(DaemonCapabilities.shared.stash)
    }

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

    /// Closes browser tabs `tabs` (or the unpinned pages of `workspace`) into one stash.
    func stash(tabs: [ResourceID], workspace: ResourceID?) {
        host?.registry.track(Task { @MainActor in
            do {
                let state = try self.state()
                if let workspace {
                    _ = try await state.stashWorkspace(workspace)
                } else {
                    _ = try await state.stashTabs(tabs)
                }
            } catch {
                return ActionWorkFailure(String(describing: Self.failure(error)))
            }
            await model.reload()
            return nil
        })
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
