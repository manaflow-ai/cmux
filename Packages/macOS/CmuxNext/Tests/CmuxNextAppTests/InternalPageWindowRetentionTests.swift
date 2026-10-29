import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import Foundation
import Testing

/// The page tab store holds each tab's window weakly. A closed window with a restorable
/// page tab is freed, with every workspace it parked; the tab stays. A Chrome tab helper holds a
/// `raw_ptr<Browser>` and finds its window again with `chrome::FindBrowserWithTab`
/// (chrome/browser/ui/browser_finder.cc); it never owns the window.
@MainActor
private final class WindowRecordingPage: InternalPageProvider {
    let page: InternalPageID
    let title = "Window page"
    let symbol = "doc"
    /// The window `makeView(for:in:)` got for each key, nil when it got none.
    private(set) var windows: [String: ObjectIdentifier?] = [:]

    init(_ page: InternalPageID) { self.page = page }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        windows[key] = window.map { ObjectIdentifier($0) }
        return NSView()
    }
}

/// The keys a test's ``InternalPageTabStore/findWindow`` was asked for.
@MainActor
private final class AskedKeys {
    var keys: [String] = []
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct InternalPageWindowRetentionTests {
    private static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        return services
    }

    private static func window(_ id: String, services: AppServices) throws -> WindowController {
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"\#(id)","workspace_key":"k-\#(id)"}"#.utf8))
        return WindowController(state: WindowState(record: record), services: services,
                                frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
    }

    private static func close(_ controller: WindowController) {
        controller.teardown()
        controller.window?.close()
    }

    /// Lets the closed window's cancelled observation tasks end: a fixed number of yields, one turn's work.
    private static func drainMain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Red on base: the store kept `[String: WindowController]` strongly until the tab closed.
    @Test func aClosedWindowWithAPageTabIsFreedAndTheTabStays() async throws {
        let services = Self.services()
        defer { withExtendedLifetime(services) {} }
        let pages = InternalPageTabStore()
        let provider = WindowRecordingPage(InternalPageID(rawValue: "test.window-retention"))
        pages.register(provider)
        let store = DaemonStore()

        weak var second: WindowController?
        weak var control: WindowController?
        let key: String = try autoreleasepool {
            let controller = try Self.window("retention-second", services: services)
            second = controller
            let key = pages.open(provider.page, in: "pane-second", of: store, window: controller)
            // The same window lifecycle with no page tab: anything else that kept closed windows shows here.
            let untouched = try Self.window("retention-control", services: services)
            control = untouched
            Self.close(controller)
            Self.close(untouched)
            return key
        }
        await Self.drainMain()

        try #require(control == nil, "a closed window this store never saw stayed alive: something else holds closed windows")
        #expect(second == nil, "the page tab store kept the closed window, and every workspace it parked, alive")
        #expect(pages.tabIDs(in: "pane-second") == [key], "the closed window's page tab is no longer restorable")
        // Shown again with no live window listing it: its provider gets no window, not the freed one.
        _ = try #require(pages.view(for: key))
        #expect(provider.windows[key] == .some(nil), "a tab whose window closed made its view in a window")
    }

    /// The theme scope of a tab in a live window still resolves: its provider gets that window.
    @Test func aPageTabInALiveWindowMakesItsViewInThatWindow() throws {
        let services = Self.services()
        defer { withExtendedLifetime(services) {} }
        let pages = InternalPageTabStore()
        let provider = WindowRecordingPage(InternalPageID(rawValue: "test.window-live"))
        pages.register(provider)
        let live = try Self.window("retention-live", services: services)
        defer { Self.close(live) }

        let key = pages.open(provider.page, in: "pane-live", of: DaemonStore(), window: live)
        _ = try #require(pages.view(for: key))
        #expect(provider.windows[key] == .some(.some(ObjectIdentifier(live))), "a live window's page tab lost its window")
        #expect(pages.window(of: key) === live)
    }

    /// A tab whose window closed finds the live window that lists it now (``InternalPageTabStore/findWindow``).
    @Test func aPageTabWhoseWindowClosedFindsTheLiveWindowThatListsIt() async throws {
        let services = Self.services()
        defer { withExtendedLifetime(services) {} }
        let pages = InternalPageTabStore()
        let provider = WindowRecordingPage(InternalPageID(rawValue: "test.window-found"))
        pages.register(provider)
        let live = try Self.window("retention-found", services: services)
        defer { Self.close(live) }
        let asked = AskedKeys()
        pages.findWindow = { [weak live] key in
            asked.keys.append(key)
            return live
        }

        weak var gone: WindowController?
        let key: String = try autoreleasepool {
            let controller = try Self.window("retention-gone", services: services)
            gone = controller
            let key = pages.open(provider.page, in: "pane-moved", of: DaemonStore(), window: controller)
            Self.close(controller)
            return key
        }
        await Self.drainMain()
        try #require(gone == nil, "the closed window stayed alive")
        #expect(asked.keys.isEmpty, "the store looked a window up before any caller needed one")

        _ = try #require(pages.view(for: key))
        #expect(provider.windows[key] == .some(.some(ObjectIdentifier(live))), "the tab's view did not get the live window that lists it")
        #expect(asked.keys == [key])
        // Found once: the store remembers it while that window lives.
        #expect(pages.window(of: key) === live)
        #expect(asked.keys == [key], "the store looked the live window up again")
    }
}
