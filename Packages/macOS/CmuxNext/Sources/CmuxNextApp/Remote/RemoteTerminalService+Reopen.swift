import CmuxNextActions
import CmuxNextDaemon
import Foundation
import os

/// A tab with no process to reference moves to another machine's workspace by reopening there
/// (unimplemented audit row 11): a browser tab on its page (URL, engine, and its profile when known
/// there), an agent chat on its acpmux session, a page tab on its page and route. Home, a
/// conversation and an app tab belong to their machine: they are refused and stay.
extension RemoteTerminalService {
    func reopen(_ tab: TabModel, in pane: PaneModel, closingOn source: DaemonConnection, on destination: DaemonConnection,
                completion: @escaping (Bool) -> Void) {
        let browserTabs = services.cache.browserTabs, handle = pane.handle, route = tab.pageRoute
        if tab.kind == .browser, tab.appTab == nil {
            switch browserTabs.resolve(requested: nil, inherited: tab.browserEngine) {
            case .refuse(let reason): services.registry.refuse(BrowserTabService.message(reason)); completion(false)
            case .open(let choice):
                let (url, profile) = (services.browserProfiles.currentURL(of: tab), tab.browserProfileID)
                land(tab, closingOn: source, on: destination, completion: completion) { try await browserTabs.open(choice, in: pane, url: url, profile: profile) }
            }
        } else if let session = tab.agentSession {
            land(tab, closingOn: source, on: destination, completion: completion) { try await destination.request(NewConversationTabRequest(agentSession: session, pane: handle)).surface }
        } else if let page = tab.page {
            land(tab, closingOn: source, on: destination, completion: completion) { try await destination.request(NewConversationTabRequest(page: page, route: route, pane: handle)).surface }
        } else {
            services.registry.refuse(RemoteStrings.moveTabAcrossMachines); completion(false)
        }
    }

    /// Opens `tab`'s new tab on `destination` (`open`), then closes the original on `source`. Its name and pin come
    /// along (best effort: a daemon without tab metadata keeps it unpinned, and the move still lands).
    func land(_ tab: TabModel, closingOn source: DaemonConnection, on destination: DaemonConnection, completion: @escaping (Bool) -> Void,
              open: @escaping @MainActor () async throws -> SurfaceID) {
        let (name, pinned, surface, id, terminal) = (tab.name.flatMap { $0.isEmpty ? nil : $0 }, tab.pinned, tab.surface, tab.id, tab.kind == .pty || tab.kind == .remoteTerminal)
        services.registry.track(Task { [weak self] in
            do {
                let created = try await open()
                if let name { try? await destination.renameTab(created, to: name) }
                if pinned { _ = try? await destination.setTabPinned(created, true) }
                do { try await source.closeTab(surface) } catch { self?.originalStayed(error); completion(true); return nil } // landed: a pinned original stays
                self?.forget(tabID: id)
                if !terminal { self?.services.cache.release(id) } // its page closes with it
                completion(true); return nil
            } catch {
                completion(false); return ActionWorkFailure(terminal ? "move terminal to another machine" : "move tab to another machine", error)
            }
        })
    }
    /// The moved tab landed but its original here could not close: logged, and one notice for the person.
    private func originalStayed(_ error: any Error) {
        Logger(subsystem: "com.cmuxterm.next", category: "remote").notice("moved tab's original stayed: \(String(describing: error), privacy: .public)")
        services.refusalHUD.show(RemoteStrings.originalTabStayed, in: services.windows.active?.window ?? services.keyWindowSource())
    }
}
