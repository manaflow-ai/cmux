import CmuxNextActions
import CmuxNextDaemon
import Foundation
import Observation

/// beside_caller in the app (hq-6d right-column design). The control router
/// picks the pane (ControlCaller): the column right of the agent's chat, or,
/// with no column there, the chat's own pane with `newColumnBeside`. Here the
/// new tab is made in that pane without moving keyboard focus out of the
/// chat: selected in the column right of the chat, or made unselected in the
/// chat's pane and moved into a new column right of it, so the chat pane
/// never shows it.
enum AgentBesidePlacement {
    /// What runs once the new tab's surface exists, for a tab opened in
    /// `controller` by an agent beside its chat; `then` runs first.
    @MainActor static func placed(_ invocation: ActionInvocation, in controller: PaneController,
                                  then: (@MainActor (SurfaceID) -> Void)?) -> @MainActor (SurfaceID) -> Void {
        let services = controller.services, anchor = controller.pane
        let newColumn = invocation.newColumnBeside
        return { [weak controller] surface in
            then?(surface)
            if newColumn {
                moveToNewColumn(surface, rightOf: anchor, services: services)
            } else {
                controller?.selectWhenReportedKeepingFocus(surface: surface)
            }
        }
    }

    /// A browser tab an agent opens beside its chat (`openBrowser`).
    @MainActor static func openBrowser(_ invocation: ActionInvocation, url: URL?, engine: String?, in controller: PaneController,
                                       then: (@MainActor (SurfaceID) -> Void)?) {
        _ = controller.newBrowserTab(url: url, engine: engine, background: invocation.newColumnBeside,
                                     then: placed(invocation, in: controller, then: then))
    }

    /// Moves the tab on `surface` out of `anchor` into a new column right of
    /// it, once the store lists the tab (the daemon's reply can come before
    /// its echo).
    @MainActor static func moveToNewColumn(_ surface: SurfaceID, rightOf anchor: PaneModel, services: AppServices) {
        services.registry.track(Task { @MainActor in
            guard let tab = await reported(surface, services: services) else { return "beside-caller: the new tab was never listed" }
            TabMoves.toNewColumn(tab, anchor: anchor, services: services)
            return nil
        })
    }

    @MainActor private static func reported(_ surface: SurfaceID, services: AppServices) async -> TabModel? {
        for await tab in Observations({ services.locateTab(surface: surface) }) {
            if let tab { return tab }
        }
        return nil
    }
}
