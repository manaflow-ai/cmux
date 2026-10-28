#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextOracle
import CmuxNextWakeups
import Observation
import Testing

/// The app's `windows` facet: the app list provides it; it orders the window manager's windows
/// by the registry's recency (an unregistered launch window first), names as key and main the controller that
/// owns AppKit's key and main window (a page window or sheet over it counts as it), and a wait on it wakes on
/// AppKit's window notifications. Run: `swift test --filter OracleWindowsAppFacetTests`.
@MainActor @Suite(.serialized) struct OracleWindowsAppFacetTests {
    private struct Harness {
        let services: AppServices
        let a: WindowController
        let b: WindowController
        let c: WindowController

        func id(_ controller: WindowController) -> String { ControlWindowInfo.publicID(forKey: controller.state.id) }

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
        }
    }

    /// Three registered windows, activated so that the registry's recency is a, b, c (front to back).
    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let a = try #require(services.windows.openWindow(workspaces: ["ow-a"]))
        let b = try #require(services.windows.openWindow(workspaces: ["ow-b"]))
        let c = try #require(services.windows.openWindow(workspaces: ["ow-c"]))
        for controller in [c, b, a] { services.windows.didActivate(controller) }
        return Harness(services: services, a: a, b: b, c: c)
    }

    private static func borderless() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func theAppListProvidesTheFacet() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.windows))
        #expect(facets.signalsChanges(.windows))
        // No window open: an empty list, not an error.
        let result = try #require(try facets.beginCapture([.windows]).completed?["windows"])
        #expect(result == ["count": 0, "order": [], "key": nil, "main": nil, "list": []])
    }

    /// The order is the registry's recency, front to back, and follows a later activation; a window the registry
    /// does not list yet (the launch window) comes first.
    @Test func theOrderIsTheRegistrysRecencyWithTheLaunchWindowFirst() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.services.windows
        let reading = windows.oracleWindows(key: nil, main: nil, screens: NSScreen.screens)
        #expect(reading.windows.map(\.id) == [harness.a, harness.b, harness.c].map(harness.id))
        #expect(reading.windows.map(\.id) == windows.registry.value.recency.map { ControlWindowInfo.publicID(forKey: $0) })
        windows.didActivate(harness.c)
        #expect(windows.oracleWindows(key: nil, main: nil, screens: NSScreen.screens).windows.map(\.id)
            == [harness.c, harness.a, harness.b].map(harness.id), "the activated window comes to the front")
        let launch = windows.makeController(for: WindowRegistry.Window(id: "ow-launch"))
        defer { launch.teardown() }
        #expect(windows.oracleWindows(key: nil, main: nil, screens: NSScreen.screens).windows.map(\.id)
            == [launch, harness.c, harness.a, harness.b].map(harness.id), "the unregistered launch window is first")
    }

    /// Key and main name the cmux window that owns AppKit's key and main window: the window itself, its Chromium
    /// page window or a sheet over it. A window no controller owns is no cmux window.
    @Test func keyAndMainNameTheOwningWindow() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let windows = harness.services.windows
        let shellA = try #require(harness.a.window), shellB = try #require(harness.b.window)
        let page = Self.borderless(), stranger = Self.borderless()
        shellB.addChildWindow(page, ordered: .above)
        defer { shellB.removeChildWindow(page); page.close(); stranger.close() }
        let direct = windows.oracleWindows(key: shellA, main: shellA, screens: NSScreen.screens)
        #expect(direct.key == harness.id(harness.a))
        #expect(direct.main == harness.id(harness.a))
        let overPage = windows.oracleWindows(key: page, main: shellB, screens: NSScreen.screens)
        #expect(overPage.key == harness.id(harness.b), "a focused page window reads as its cmux window")
        #expect(overPage.main == harness.id(harness.b))
        let elsewhere = windows.oracleWindows(key: stranger, main: nil, screens: NSScreen.screens)
        #expect(elsewhere.key == nil)
        #expect(elsewhere.main == nil)
        // Through the app's facet list: the services' key window seam is what the facet reads. A host with no
        // display has no screen to measure the frames against, so the snapshot fails there by design.
        guard !NSScreen.screens.isEmpty else { return }
        harness.services.keyWindowSource = { page }
        let snapshot = try #require(try harness.services.makeOracleFacets().beginCapture([.windows]).completed?["windows"])
        #expect(snapshot["key"] == .string(harness.id(harness.b)))
        #expect(snapshot["count"] == 3)
    }

    /// Reads the facet under Observation tracking, as `debug.oracle.wait_for` does: the stream yields when
    /// anything the read observed changes.
    private static func trackedRead(_ facet: OracleWindowsFacet) -> AsyncStream<Void> {
        let (changed, change) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard case .mainActor(let read) = facet.capture else {
            Issue.record("the windows facet is not read on the main actor")
            change.finish()
            return changed
        }
        withObservationTracking { _ = try? read() } onChange: { change.yield() }
        return changed
    }

    /// Each AppKit window notification wakes a wait on the facet (frames, full screen and miniaturize are not
    /// observable), through one app-events subscription per name however many reads.
    @Test func eachWindowNotificationWakesAWait() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let facet = services.windows.oracleWindowsFacet(events: events)
        let window = Self.borderless()
        defer { window.close() }
        for name in WindowEvents.stateChanges {
            var changed = Self.trackedRead(facet).makeAsyncIterator()
            center.post(name: name, object: window)
            #expect(await changed.next() != nil, "\(name.rawValue) did not wake the wait")
        }
        for name in WindowEvents.stateChanges {
            #expect(events.subscriberCount(name) == 1, "\(name.rawValue) subscribed again on a later read")
        }
    }

    /// A real resize (AppKit posts didResize) wakes a `wait_for` on a frame pointer.
    @Test func aResizeWakesAWait() async throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let shell = try #require(harness.a.window)
        var changed = Self.trackedRead(harness.services.windows.oracleWindowsFacet(events: harness.services.appEvents)).makeAsyncIterator()
        var frame = shell.frame
        frame.size.width += 40
        shell.setFrame(frame, display: false)
        #expect(await changed.next() != nil, "setFrame did not wake the wait")
    }
}
#endif
