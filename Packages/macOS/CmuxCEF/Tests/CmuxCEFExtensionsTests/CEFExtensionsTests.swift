import AppKit
import CmuxBrowser
import CmuxCEF
import Foundation
import Testing
@testable import CmuxCEFExtensions

@MainActor
private final class FakeCalls: CEFExtensionCalls {
    var forkAPIVersion: Int32 = 13
    var listJSON = "[]"
    var actionsJSON = "[]"
    var log: [String] = []
    var replies: [(Int32, Int32)] = []
    var windows: [Int32: Int32] = [:]

    func list(browser: Int32) -> String? { log.append("list \(browser)"); return listJSON }
    func commands(browser: Int32) -> String? { "[]" }
    func actions(browser: Int32, iconPixels: Int32) -> String? { log.append("actions \(browser)"); return actionsJSON }
    func setEnabled(browser: Int32, id: String, enabled: Bool) -> Bool { log.append("enable \(browser) \(id) \(enabled)"); return true }
    func uninstall(browser: Int32, id: String) -> Bool { log.append("uninstall \(browser) \(id)"); return true }
    func reload(browser: Int32, id: String) -> Bool { log.append("reload \(browser) \(id)"); return true }
    func movePinned(browser: Int32, id: String, index: Int) -> Bool { log.append("move \(id) \(index)"); return true }
    func setPinned(browser: Int32, id: String, pinned: Bool) -> Bool { log.append("pin \(id) \(pinned)"); return true }
    func openOptions(browser: Int32, id: String) -> Bool { log.append("options \(browser) \(id)"); return true }
    func loadUnpacked(browser: Int32, path: String) -> Bool { log.append("load \(browser) \(path)"); return true }
    func runCommand(browser: Int32, id: String, command: String) -> Bool { log.append("command \(browser) \(id) \(command)"); return true }
    func runAction(browser: Int32, id: String, x: Int32, width: Int32) -> Bool { log.append("run \(browser) \(id) \(x) \(width)"); return true }
    func hidePopup(browser: Int32, id: String) { log.append("hide \(browser) \(id)") }
    func showActionMenu(browser: Int32, id: String, x: Int32, y: Int32) { log.append("menu \(id) \(x) \(y)") }
    func replyToPrompt(_ promptID: Int32, answer: Int32) -> Bool { replies.append((promptID, answer)); return true }
    func windowID(browser: Int32) -> Int32 { windows[browser] ?? 0 }
}

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
@Suite("Chromium extension stores, pages and prompts")
struct CEFExtensionsTests {
    private let profile = UUID()

    @Test
    func storeAnchorsOnALivePageOfItsProfile() {
        let calls = FakeCalls()
        calls.listJSON = #"[{"id":"a","name":"A","enabled":true}]"#
        let stores = CEFExtensionStores(calls: calls)
        let store = stores.store(for: profile)
        store.refresh()
        #expect(store.extensions.isEmpty, "no live page: nothing to anchor on")
        let other = CEFExtensionPageSupport(profileID: UUID(), stores: stores) { 9 }
        store.refresh()
        #expect(store.extensions.isEmpty, "a page of another profile is not an anchor")
        let page = CEFExtensionPageSupport(profileID: profile, stores: stores) { 7 }
        store.refresh()
        #expect(store.extensions.map(\.id) == ["a"])
        #expect(calls.log.contains("list 7"))
        #expect(store.setPinned("a", true))
        #expect(calls.log.contains("pin a true"))
        #expect(store.openOptions("a", from: page))
        #expect(calls.log.contains("options 7 a"))
        _ = other
    }

    @Test
    func olderForksOnlyListActionsAndRefuseManagement() {
        let calls = FakeCalls()
        calls.forkAPIVersion = 2
        calls.actionsJSON = #"[{"id":"x","name":"X","pinned":true}]"#
        let stores = CEFExtensionStores(calls: calls)
        let page = CEFExtensionPageSupport(profileID: profile, stores: stores) { 3 }
        let store = stores.store(for: profile)
        store.refresh()
        #expect(store.extensions.first?.mayModify == false)
        #expect(!store.uninstall("x"))
        #expect(!calls.log.contains { $0.hasPrefix("uninstall") })
        _ = page
    }

    @Test
    func reloadFallsBackToDisableEnableBeforeAPI5() {
        let calls = FakeCalls()
        calls.forkAPIVersion = 4
        let stores = CEFExtensionStores(calls: calls)
        let page = CEFExtensionPageSupport(profileID: profile, stores: stores) { 1 }
        #expect(stores.store(for: profile).reload("e"))
        #expect(calls.log.contains("enable 1 e false"))
        #expect(calls.log.contains("enable 1 e true"))
        #expect(!calls.log.contains { $0.hasPrefix("reload") })
        _ = page
    }

    @Test
    func actionsRefreshRunAndPopupLifecycle() {
        let calls = FakeCalls()
        calls.actionsJSON = #"[{"id":"p","name":"P","has_popup":true}]"#
        calls.windows = [5: 50]
        let stores = CEFExtensionStores(calls: calls)
        let browser = Box<Int32?>(nil)
        let page = CEFExtensionPageSupport(profileID: profile, stores: stores) { browser.value }
        #expect(page.run("p", anchorX: 10, width: 22), "queued until the browser exists")
        #expect(!calls.log.contains { $0.hasPrefix("run") })
        browser.value = 5
        page.browserCreated()
        #expect(page.actions.map(\.id) == ["p"])
        #expect(calls.log.contains("run 5 p 10 22"))
        #expect(page.openPopup == "p")
        stores.handle(.extensionPopupClosed, browser: 99, window: 50)
        #expect(page.openPopup == nil, "a popup-closed event for the page's window clears it")
        calls.actionsJSON = "[]"
        stores.handle(.extensionActionsChanged, browser: 5, window: 50)
        #expect(page.actions.isEmpty)
    }

    @Test
    func aPageThatLeavesTheScreenClosesItsPopup() {
        let calls = FakeCalls()
        calls.actionsJSON = #"[{"id":"p","name":"P","has_popup":true}]"#
        let stores = CEFExtensionStores(calls: calls)
        let page = CEFExtensionPageSupport(profileID: profile, stores: stores) { 4 }
        page.browserCreated()
        page.pageLeftScreen()
        #expect(!calls.log.contains { $0.hasPrefix("hide") }, "no popup open: nothing to close")
        #expect(page.run("p", anchorX: 0, width: 22))
        #expect(page.openPopup == "p")
        // Another workspace or tab shows: Chrome closes a popup that loses
        // focus, so it must not reappear, stale, when the page returns.
        page.pageLeftScreen()
        #expect(calls.log.contains("hide 4 p"))
        #expect(page.openPopup == nil)
    }

    @Test
    func requestedActionGoesThroughTheToolbarWhenItIsAttached() {
        let calls = FakeCalls()
        let stores = CEFExtensionStores(calls: calls)
        let page = CEFExtensionPageSupport(profileID: profile, stores: stores) { 2 }
        let requested = Box<[String]>([])
        page.extensionActionRequestHandler = { requested.value.append($0) }
        page.requestExtensionAction("z")
        #expect(requested.value == ["z"])
        page.extensionActionRequestHandler = nil
        page.requestExtensionAction("z")
        #expect(calls.log.contains("run 2 z 0 1"))
    }

    @Test
    func promptWithoutAWindowIsAbortedAndNoticeNeedsNoReply() {
        let calls = FakeCalls()
        let notices = Box<[String]>([])
        let prompts = CEFExtensionPrompts(
            calls: calls, window: { _ in nil }, present: { _, _, _ in true },
            installed: { notice, _ in notices.value.append(notice.extensionID) }
        )
        prompts.arrived(promptID: 4, browser: 1, json: #"{"type":"install","extension_id":"e","name":"E"}"#)
        #expect(calls.replies.count == 1)
        #expect(calls.replies.first?.0 == 4 && calls.replies.first?.1 == 0)
        prompts.arrived(promptID: 0, browser: 1, json: #"{"type":"installed","extension_id":"e","name":"E"}"#)
        #expect(notices.value == ["e"])
        #expect(calls.replies.count == 1)
        prompts.arrived(promptID: 5, browser: 1, json: "garbage")
        #expect(calls.replies.last?.0 == 5 && calls.replies.last?.1 == 0)
    }

    @Test
    func promptRepliesOnceWithThePersonsAnswer() async {
        let calls = FakeCalls()
        let window = NSWindow()
        let prompts = CEFExtensionPrompts(
            calls: calls, window: { _ in window }, present: { content, _, _ in content.title.contains("E") ? false : true },
            installed: { _, _ in }
        )
        prompts.arrived(promptID: 8, browser: 1, json: #"{"type":"install","extension_id":"e","name":"E"}"#)
        #expect(prompts.waiting.map(\.id) == [8])
        for _ in 0..<20 where calls.replies.isEmpty { await Task.yield() }
        #expect(calls.replies.count == 1)
        #expect(calls.replies.first?.1 == BrowserExtensionInstallPrompt.Answer.cancel.rawValue)
        #expect(prompts.waiting.isEmpty)
    }
}
