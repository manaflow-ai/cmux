import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

@MainActor
struct PageContextMenuGestureTests {
    @Test(arguments: [false, true])
    func aChoiceAfterThirtySecondsRenewsTheSharedHostsGesture(chromium: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Menu</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let hosting = FakeChromiumHosting()
        hosting.preference = chromium ? .chromium : .webkit
        let descriptor = PageDescriptor(id: "test.menu-gesture", resource: "menu-gesture", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        defer { view.close() }
        #expect(view.showsChromium == chromium)
        let chosenAt = ProcessInfo.processInfo.systemUptime
        let openedAt = chosenAt - 31
        if chromium { view.chromiumUserInput(at: openedAt) }
        else { view.webView.noteNativeMenuSelection(at: openedAt) }
        #expect(view.recentUserGestureEvent(now: chosenAt) == nil)

        // Closing without a choice grants no new authorization.
        let dismissed = view.finishContextMenu(nil, at: chosenAt)
        #expect(dismissed["picked"] == .null)
        #expect(view.recentUserGestureEvent(now: chosenAt) == nil)

        let picked = view.finishContextMenu("scrollToBottomOnSend", at: chosenAt)
        #expect(picked["picked"] == .string("scrollToBottomOnSend"))
        #expect(view.recentUserGestureEvent(now: chosenAt) == chosenAt)
        // The router sees the fresh host value for the setting call following the native reply.
        #expect(view.router.userGestureEvent?() == chosenAt)

        let cancelled = Task { @MainActor in view.finishContextMenu("scrollToBottomOnSend", at: chosenAt + 31) }
        cancelled.cancel()
        let stale = await cancelled.value
        #expect(stale["picked"] == .null)
        #expect(view.recentUserGestureEvent(now: chosenAt + 31) == nil)
    }
}
