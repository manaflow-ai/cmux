import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import Testing
@testable import CmuxNextApp

/// R131: a window resigning key captures its shown pages only when the
/// keyboard leaves the window's family (another top-level window, or the
/// app resigned active), never when its own child page window, popup or
/// sheet takes the key.
@MainActor @Suite struct WindowKeyFamilyTests {
    final class Win {
        let name: String
        var owner: Win?
        init(_ name: String, owner: Win? = nil) { self.name = name; self.owner = owner }
    }

    final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theFamilyIsTheWindowItsChildrenAndItsSheets() {
        let main = Win("main"), page = Win("page", owner: main), popup = Win("popup", owner: page)
        let sheet = Win("sheet", owner: main), other = Win("other")
        func left(_ newKey: Win?) -> Bool { WindowKeyFamily.leftFamily(of: main, newKey: newKey, owner: \.owner) }
        #expect(!left(page), "a child page window")
        #expect(!left(popup), "a descendant")
        #expect(!left(sheet), "an attached sheet")
        #expect(!left(main), "the key came back before the check")
        #expect(left(other), "another top-level window")
        #expect(left(nil), "the app resigned active")
    }

    @Test func keyMovingToAChildCapturesNothingAndToAnotherWindowCapturesOnce() async throws {
        let cache = TabContentCache(daemon: DaemonService())
        let page = MockBrowserEngine(kind: .webkit).makeMockTab(BrowserTabConfiguration())
        cache.install(page, for: "tab")
        let pane = Pane()
        cache.present("tab", by: pane, presence: .visible)
        let main = Win("main"), child = Win("page", owner: main), other = Win("other")

        WindowKeyFamily.windowResignedKey(main, newKey: child, owner: \.owner, presenters: [pane], cache: cache)
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(page.snapshotCount == 0, "key moved to the window's own page window: no capture")

        WindowKeyFamily.windowResignedKey(main, newKey: other, owner: \.owner, presenters: [pane], cache: cache)
        try await eventually { cache.pageThumbnails.image(for: "tab") != nil }
        #expect(page.snapshotCount == 1, "key moved to another window: one capture")
    }
}
