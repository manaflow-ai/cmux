import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// #37134: the next Cmd-N's reservation (idle work, #36962) takes the parked New Tab spare, and nothing opens. Its page
/// is mounted hidden and draws no frame until the key, so a take as an open waited for that frame before the pool made
/// the next spare: the refill waited for the quiet-input backstop (750 ms of no input), which each key or scroll pushes
/// back, so a person typing kept the pool one spare short. The take was also recorded as an opening (`debug.new_tab`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabSpareReservationTests {
    /// One scroll with no distance, as the pool's input monitor sees a person's input (`NSApp.sendEvent`).
    static func input() {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return }
        NSApp.sendEvent(event)
    }

    @Test func aReservationTakesTheSpareAsIdleWorkAndThePoolRefillsWhileThePersonTypes() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-reservation")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, _) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try NewTabRapidPairTests.folder()
            var rig: NewTabRapidPairTests.Rig?
            defer { NewTabRapidPairTests.cleanUp(services, rig, folder) }
            // The parked spares report no frame, as a page mounted hidden (the reserved Cmd-N page) draws none.
            rig = try await NewTabRapidPairTests.filledPool(services, window: window, folder: folder, framed: { _ in false })
            let pool = services.newTabSpares, tabs = services.agentTabs, daemon = services.daemon
            // A reservation the launch made took its page already: let it go, so the next one takes the parked spare.
            tabs.releaseReservedWorkspace(on: daemon.store, .unshown)
            let spare = try #require(pool.spare?.view)
            let openings = pool.openings.count, made = rig?.made.count ?? 0

            _ = try #require(tabs.reserveWorkspace(on: daemon, cwd: folder.path), "no Cmd-N workspace was reserved")
            #expect(tabs.views.values.contains { $0 === spare }, "the reservation did not take the parked spare")
            #expect(pool.openings.count == openings,
                    "the reservation recorded an opening, though nothing opened (spare per opening: \(pool.openings.dropFirst(openings).map(\.spare)))")

            // The person types (an input every 100 ms keeps the quiet-input backstop away): the pool makes the next spare
            // after the take's frame commit and settle (250 ms), with no frame of the hidden page to wait for.
            let start = ContinuousClock.now
            while (rig?.made.count ?? 0) <= made, ContinuousClock.now - start < .seconds(3) {
                Self.input()
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect((rig?.made.count ?? 0) > made,
                    "the pool made no spare in 3 s of input after the reservation took one (it waits for the hidden page's frame)")
        }
    }
}
