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
    /// How long the move waits for the new tab: its open, then the store's echo.
    static let openLimit: Duration = .seconds(20)

    /// The `then` of a tab an agent opens in `controller` beside its chat;
    /// `then` runs first. Call it while the handler runs: the move into a
    /// new column is work of the run (`registry.track`), so `action.run`
    /// answers after it, with the tab in its final pane.
    @MainActor static func placed(_ invocation: ActionInvocation, in controller: PaneController,
                                  then: (@MainActor (SurfaceID) -> Void)?) -> @MainActor (SurfaceID) -> Void {
        guard invocation.newColumnBeside else {
            return { [weak controller] surface in
                then?(surface)
                controller?.selectWhenReportedKeepingFocus(surface: surface)
            }
        }
        let services = controller.services, anchor = controller.pane
        let (surfaces, sink) = AsyncStream<SurfaceID>.makeStream(bufferingPolicy: .bufferingNewest(1))
        services.registry.track(Task { @MainActor in
            guard let surface = await within(openLimit, { await surfaces.first { _ in true } }) ?? nil else {
                return "beside-caller: the new tab did not open"
            }
            guard await within(openLimit, { await reported(surface, services: services) }) == true,
                  let tab = services.locateTab(surface: surface) else {
                return "beside-caller: the new tab was never listed"
            }
            let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                TabMoves.toNewColumn(tab, anchor: anchor, services: services) { done.resume(returning: $0) }
            }
            return moved ? nil : "beside-caller: the move into a new column failed (see the app log)"
        })
        return { surface in
            then?(surface)
            sink.yield(surface)
            sink.finish()
        }
    }

    /// The tab on `surface` once the store lists it (the daemon's reply can come before its echo).
    @MainActor private static func reported(_ surface: SurfaceID, services: AppServices) async -> Bool {
        for await listed in Observations({ services.locateTab(surface: surface) != nil }) where listed {
            return true
        }
        return false
    }

    /// `body`'s value, or nil when `limit` passes first (an intentional bound,
    /// so a tab that never opens cannot hold the run).
    @MainActor private static func within<T: Sendable>(_ limit: Duration, _ body: @escaping @MainActor () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { @MainActor in await body() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
