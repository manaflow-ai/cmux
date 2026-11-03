#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesignTokens
import CmuxNextSettings
import Observation
import Testing

/// `debug.tunables` `activate` (FRAME OWNER REFACTOR S0). The fleet films Release builds with bench hooks
/// (CMUX_BENCH_HOOKS). Their launch never turns the tunable store on (`DevTools`: not a Debug compile, not a nightly
/// bundle), so a `set` changed nothing there, and one build could not film a Debug switch off and on or scale the
/// springs for the speed sweep. `activate` turns that store on for the launch, in memory only.
/// Each test drives a store of its own: other suites turn `TunableStore.shared` on, and a store never turns off.
@MainActor @Suite(.serialized)
struct DebugTunablesActivateTests {
    private static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// `debug.tunables` with `params` on `store`, as the socket method calls it on the shared store.
    private static func call(_ params: [String: CmuxNextSettings.JSONValue], _ store: TunableStore,
                             _ services: AppServices) -> CmuxNextSettings.JSONValue {
        DebugTunables.handle(params, services: services, store: store)
    }

    /// No `activate`, no change: a store that launch left off refuses a `set` and reports itself off, as every
    /// bench that never calls `activate` still sees it.
    @Test func withoutActivateASetChangesNothing() {
        let services = Self.services(), store = TunableStore()
        let row = Self.call(["action": "set", "key": "browserResize.pageBackdrop", "value": false], store, services)
        #expect(row["value"]?.boolValue == true)
        #expect(row["changed"]?.boolValue == false)
        #expect(BrowserResizeTunables.pageBackdrop.value(in: store) == true)
        #expect(Self.call(["action": "state"], store, services)["active"]?.boolValue == false)
    }

    /// After `activate`, `state` says active, and each `set` reaches the next read: a switch
    /// read per frame (`browserResize.pageBackdrop`) and a spring read when its motion starts (`motion.spring.move`,
    /// which the speed sweep scales).
    @Test func activateTurnsTheStoreOnAndEachSetReachesTheNextRead() throws {
        let services = Self.services(), store = TunableStore()
        let state = Self.call(["action": "activate"], store, services)
        #expect(state["error"] == nil, "the action exists")
        #expect(state["active"]?.boolValue == true)
        let backdrop = BrowserResizeTunables.pageBackdrop
        let row = Self.call(["action": "set", "key": .string(backdrop.key), "value": false], store, services)
        #expect(row["value"]?.boolValue == false)
        #expect(row["changed"]?.boolValue == true)
        #expect(backdrop.value(in: store) == false)
        _ = Self.call(["action": "set", "key": .string(backdrop.key), "value": true], store, services)
        #expect(backdrop.value(in: store) == true)
        let move = try #require(MotionTunables.springs[.move])
        _ = Self.call(["action": "set", "key": .string(move.key), "value": ["response": 0.6, "dampingFraction": 1]], store, services)
        #expect(move.value(in: store) == SpringParameters(response: 0.6, dampingFraction: 1))
        #expect(Self.call(["action": "state"], store, services)["active"]?.boolValue == true)
    }

    /// A reader that tracks a tunable after `activate` (a view in `withObservationTracking`) is told of the next `set`.
    @Test func aReaderThatTracksAfterActivateIsToldOfTheNextSet() {
        let services = Self.services(), store = TunableStore()
        _ = Self.call(["action": "activate"], store, services)
        let changes = CmuxNextCompat.Atomic<Int>(0)
        withObservationTracking { _ = BrowserResizeTunables.pageBackdrop.value(in: store) } onChange: { changes.wrappingAdd(1, ordering: .relaxed) }
        _ = Self.call(["action": "set", "key": "browserResize.pageBackdrop", "value": false], store, services)
        #expect(changes.load(ordering: .relaxed) == 1)
    }

    /// On a store that launch already turned on (DEV and NIGHTLY), `activate` changes nothing: its overrides stay.
    @Test func activateLeavesAStoreThatIsOnAsItIs() {
        let services = Self.services(), store = TunableStore()
        store.register(BrowserResizeTunables.all)
        store.activate(file: nil)
        store.set(BrowserResizeTunables.pageBackdrop.key, .bool(false))
        let state = Self.call(["action": "activate"], store, services)
        #expect(state["error"] == nil, "the action exists")
        #expect(state["active"]?.boolValue == true)
        #expect(BrowserResizeTunables.pageBackdrop.value(in: store) == false)
    }
}
#endif
