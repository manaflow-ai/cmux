import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// A tab with no process to reference moves to another machine's workspace by reopening there
/// (unimplemented audit row 11): a browser tab on its page (URL, engine, and its profile when known
/// there), an agent chat on its acpmux session, a page tab on its page and route. Home, a
/// conversation and an app tab belong to their machine: they are refused and stay.
extension RemoteTerminalService {
    func reopen(_ tab: TabModel, in pane: PaneModel, closingOn source: DaemonConnection, on destination: DaemonConnection,
                completion: @escaping TabMoves.Completion) {
        guard let services else { return }
        let browserTabs = services.cache.browserTabs, handle = pane.handle, route = tab.pageRoute
        if tab.kind == .browser, tab.appTab == nil {
            switch browserTabs.resolve(requested: nil, inherited: tab.browserEngine) {
            case .refuse(let reason):
                services.registry.refuse(BrowserTabService.message(reason))
                completion(false)
            case .open(let choice):
                let (url, profile) = (services.browserProfiles.currentURL(of: tab), tab.browserProfileID)
                land(tab, closingOn: source, on: destination, completion: completion) { try await browserTabs.open(choice, in: pane, url: url, profile: profile) }
            }
        } else if let session = tab.agentSession {
            land(tab, closingOn: source, on: destination, completion: completion) { try await destination.request(NewConversationTabRequest(agentSession: session, pane: handle)).surface }
        } else if let page = tab.page {
            land(tab, closingOn: source, on: destination, completion: completion) { try await destination.request(NewConversationTabRequest(page: page, route: route, pane: handle)).surface }
        } else {
            services.registry.refuse(RemoteStrings.moveTabAcrossMachines)
            completion(false)
        }
    }

    /// Opens `tab`'s new tab on `destination` (`open`), then closes the original on `source`. The new
    /// tab is the same tab to the user: its name and pin come along (best effort: a daemon without tab
    /// metadata keeps it unpinned, and the move still lands). The open and the closes are awaited off main; forgetting
    /// the original and the move's completion are one task on main in the run's class (a person's: userBlocking).
    func land(_ tab: TabModel, closingOn source: DaemonConnection, on destination: DaemonConnection, completion: @escaping TabMoves.Completion,
              open: @escaping @MainActor () async throws -> SurfaceID) {
        guard let services else { return }
        let (name, pinned, surface, id) = (tab.name.flatMap { $0.isEmpty ? nil : $0 }, tab.pinned, tab.surface, tab.id)
        let terminal = tab.kind == .pty || tab.kind == .remoteTerminal
        services.registry.trackWork(owner: "RemoteTerminals.land", on: services.mainWork) { () async throws -> Void in
            let created = try await open()
            if let name { try? await destination.renameTab(created, to: name) }
            if pinned { _ = try? await destination.setTabPinned(created, true) }
            try await source.closeTab(surface)
        } then: { [weak self] result in
            if case .failure(let error) = result {
                completion(false)
                return ActionWorkFailure(terminal ? "move terminal to another machine" : "move tab to another machine", error)
            }
            self?.forget(tabID: id)
            if !terminal { self?.services?.cache.release(id) } // its page closes with it
            completion(true)
            return nil
        }
    }
}
