import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHistory
import Foundation

/// Stash (a native OneTab, `stash-v1`) on this Mac's daemon: serves the
/// Stashed page (`StashPageSource`) and closes tabs into stashes for the
/// Stash actions. The page's model is the one list every surface reads.
final class StashService: StashPageSource {
    private unowned let services: AppServices
    let model = StashPageModel()

    init(services: AppServices) {
        self.services = services
        model.source = self
    }

    /// Whether `daemon` keeps stashes; without it no stash UI shows. Only this Mac's daemon.
    func serves(_ daemon: DaemonService) -> Bool { daemon.isLocal && daemon.supports(DaemonCapabilities.shared.stash) }

    /// Runs `body` on this Mac's daemon; a failure comes back as its user-facing reason.
    private func client<T>(_ body: (StateResourceClient) async throws -> T) async throws -> T {
        guard serves(services.daemon), let connection = services.daemon.connection else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        do { return try await body(connection.state) } catch let failure as ActionFailure { throw failure } catch {
            throw ActionFailure(message: RefusalStrings.describe(error))
        }
    }

    /// Closes browser tabs `tabs` (or the unpinned pages of `workspace`) into one stash.
    func stash(tabs: [ResourceID], workspace: ResourceID?) {
        services.registry.track(Task { @MainActor in
            do {
                _ = try await client { state in
                    if let workspace { return try await state.stashWorkspace(workspace) }
                    return try await state.stashTabs(tabs)
                }
            } catch {
                return ActionWorkFailure(String(describing: error))
            }
            await model.reload()
            return nil
        })
    }

    // MARK: StashPageSource

    func stashes() async throws -> [StashedGroup] {
        try await client { try await $0.stashes() }.map { record in
            StashedGroup(id: record.id, name: record.name, createdAt: Date(timeIntervalSince1970: Double(record.createdAtMs) / 1000),
                         tabs: record.members.map { StashedGroup.Tab(url: $0.url, title: $0.title, profile: $0.browserProfileID) })
        }
    }

    func restore(_ group: StashedGroup, tabs: [Int]?, inNewWorkspace: Bool) async throws {
        try await client { try await $0.restoreStash(group.id, members: tabs, target: inNewWorkspace ? .newWorkspace : .here) }
    }

    func delete(_ group: StashedGroup, tabs: [Int]?) async throws {
        try await client { try await $0.deleteStash(group.id, members: tabs) }
    }

    /// Imported pages reopen in the app's browser engine (`browser.defaultEngine`, WebKit without Chromium).
    func importGroups(_ groups: [OneTabExport.Group]) async throws {
        let engine = switch services.cache.browserTabs.resolve(requested: nil) {
        case .open(let choice): choice.engine.rawValue
        case .refuse: BrowserEngineTag.webkit.rawValue
        }
        let wire = groups.map { group in
            StateResourceClient.StashImportGroup(name: nil, pages: group.tabs.map { .init(url: $0.url, title: $0.title) })
        }
        try await client { try await $0.importOneTab(wire, engine: engine) }
    }
}
