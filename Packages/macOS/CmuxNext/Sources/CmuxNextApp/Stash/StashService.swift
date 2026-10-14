import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHistory
import Foundation

/// Stash (a native OneTab, `stash-v1`) on this Mac's daemon: serves the
/// Stashed page (`StashPageSource`) and closes tabs into stashes for the
/// Stash actions. The page's model is the one list every surface reads.
final class StashService: StashPageSource {
    private weak var services: AppServices?
    let model = StashPageModel()

    init(services: AppServices) {
        self.services = services
        model.source = self
    }

    /// Whether `daemon` keeps stashes; without it no stash UI shows. Only this Mac's daemon.
    func serves(_ daemon: DaemonService) -> Bool { daemon.isLocal && daemon.supports(DaemonCapabilities.shared.stash) }

    /// This Mac's daemon's state client, when it keeps stashes.
    private func state() throws -> StateResourceClient {
        guard let services, serves(services.daemon), let connection = services.daemon.connection else {
            throw ActionFailure(message: MiscHandlerStrings.daemonOffline)
        }
        return connection.state
    }

    /// `error` as the user-facing reason the page shows.
    private static func failure(_ error: any Error) -> any Error {
        error is ActionFailure ? error : ActionFailure(message: RefusalStrings.describe(error))
    }

    /// Closes browser tabs `tabs` (or the unpinned pages of `workspace`) into one stash.
    func stash(tabs: [ResourceID], workspace: ResourceID?) {
        services?.registry.track(Task { @MainActor in
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

    func stashes() async throws -> [StashedGroup] {
        let records: [StashRecord]
        do { records = try await state().stashes() } catch { throw Self.failure(error) }
        return records.map { record in
            StashedGroup(id: record.id, name: record.name, createdAt: Date(timeIntervalSince1970: Double(record.createdAtMs) / 1000),
                         tabs: record.members.map { StashedGroup.Tab(url: $0.url, title: $0.title, profile: $0.browserProfileID) })
        }
    }

    func restore(_ group: StashedGroup, tabs: [Int]?, inNewWorkspace: Bool) async throws {
        do { try await state().restoreStash(group.id, members: tabs, target: inNewWorkspace ? .newWorkspace : .here) } catch {
            throw Self.failure(error)
        }
    }

    func delete(_ group: StashedGroup, tabs: [Int]?) async throws {
        do { try await state().deleteStash(group.id, members: tabs) } catch { throw Self.failure(error) }
    }

    /// Imported pages reopen in the app's browser engine (`browser.defaultEngine`, WebKit without Chromium).
    func importGroups(_ groups: [OneTabExport.Group]) async throws {
        var engine = BrowserEngineTag.webkit.rawValue
        if case .open(let choice)? = services?.cache.browserTabs.resolve(requested: nil) { engine = choice.engine.rawValue }
        let wire = groups.map { group in
            StateResourceClient.StashImportGroup(name: nil, pages: group.tabs.map { .init(url: $0.url, title: $0.title) })
        }
        do { try await state().importOneTab(wire, engine: engine) } catch { throw Self.failure(error) }
    }
}
