import CmuxNextDaemon
@testable import CmuxNextApps
import Testing

/// The daemon's widget events (`cmux.widget/1`): a layout change every page follows, and a tile's
/// health (let it crash: a stale tile keeps its last scene).
@Suite struct AppWidgetEventsTests {
    @Test func theLayoutChangeDecodes() {
        let payload = CmuxNextDaemon.JSONValue.object(["revision": .number(7), "place": .string("newtab")])
        #expect(AppsWireDecoding().event(name: "apps-widgets-changed", payload: payload) == .widgetsChanged(revision: 7, place: "newtab"))
    }

    @Test func aTilesHealthDecodesAndNeedsItsMount() {
        let payload = CmuxNextDaemon.JSONValue.object([
            "mount_id": .string("m1"), "stale": .bool(true), "reason": .string("x"), "failures": .number(1), "retry_ms": .number(1000),
        ])
        #expect(AppsWireDecoding().event(name: "apps-widget-health", payload: payload)
            == .widgetHealth(mountID: "m1", stale: true, reason: "x", retryMilliseconds: 1000))
        let healed = CmuxNextDaemon.JSONValue.object(["mount_id": .string("m1"), "stale": .bool(false)])
        #expect(AppsWireDecoding().event(name: "apps-widget-health", payload: healed)
            == .widgetHealth(mountID: "m1", stale: false, reason: nil, retryMilliseconds: nil))
        #expect(AppsWireDecoding().event(name: "apps-widget-health", payload: .object(["stale": .bool(true)])) == nil)
    }

    @Test func theWidgetSurfaceResolvesTheWidgetInterface() {
        #expect(AppMountSurface(rawValue: "widget") == .widget)
        #expect(AppImplementation.widget == "cmux.widget/1")
    }
}
