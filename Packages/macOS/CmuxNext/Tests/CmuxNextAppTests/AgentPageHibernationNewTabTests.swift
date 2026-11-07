import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextTestSupport
import Testing

/// The cap applies only to untouched local New Tabs; real chats and any page-owned edit stay.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentPageHibernationNewTabTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func rig() -> AgentPageHibernationTests.Rig {
        let rig = AgentPageHibernationTests.Rig()
        rig.hibernation.isRendering = { [unowned rig] key in rig.rendering.contains(key) }
        rig.hibernation.wakeState = { _ in AgentPaneWakeState() }
        rig.hibernation.snapshot = { _ in
            guard let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() else { return nil }
            return (image, NSSize(width: 400, height: 300), .aqua)
        }
        return rig
    }

    @discardableResult
    private func hiddenNewTab(_ key: String, in rig: AgentPageHibernationTests.Rig,
                              context: AgentPaneNewTab? = nil) throws -> AgentPaneView {
        rig.records[key] = AgentSessionRef(host: AgentPageHibernationTests.thisMac, hostName: "This Mac", harness: "claude")
        let context = context ?? AgentPaneNewTab(kind: .agent, cwd: "/tmp/hibernation-newtab")
        rig.tabs.newTabPages[key] = (context, NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        let view = try #require(rig.tabs.view(for: key))
        rig.hibernation.pageBuilt(key)
        return view
    }

    private func overflow(_ rig: AgentPageHibernationTests.Rig) throws {
        try hiddenNewTab("tab_new_2", in: rig)
        try hiddenNewTab("tab_new_3", in: rig)
    }

    @Test func anUntouchedChromiumNewTabUsesItsNativeContextWithoutCapturingAHiddenSurface() async throws {
        let rig = rig()
        defer { rig.window.closeAfterTest() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "hibernation-newtab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let key = "tab_chromium_new"
        let context = AgentPaneNewTab(kind: .agent, cwd: "/tmp/hibernation-newtab")
        try hiddenNewTab(key, in: rig, context: context)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: context), source: .bundled(file),
                                             pageHost: true, testRoot: true, chromium: hosting))
        defer { view.close() }
        await view.page?.chromiumStart?.value
        try #require(view.pageDrawsOverCovers)
        rig.tabs.views[key] = view
        var captures = 0
        rig.hibernation.snapshot = { _ in captures += 1; return nil }
        try overflow(rig)
        rig.elapsed += .seconds(11)
        rig.hibernation.replan()
        await rig.settle { rig.tabs.existingView(key) == nil }
        #expect(rig.tabs.existingView(key) == nil)
        #expect(captures == 0, "hidden Chromium surfaces must never be captured for the New Tab cap")
        #expect(rig.tabs.newTabPages[key]?.page.cwd == context.cwd)
        #expect(rig.records[key]?.session == nil)
        #expect(try #require(rig.tabs.view(for: key)).model.newTab?.cwd == context.cwd)
    }

    @Test func theTwoNewestHiddenWebKitNewTabsStayWarmAndTheOldestKeepsItsContext() async throws {
        let rig = rig()
        defer { rig.window.closeAfterTest() }
        let key = "tab_oldest"
        let view = try hiddenNewTab(key, in: rig)
        try overflow(rig)
        rig.elapsed += .seconds(9)
        rig.hibernation.replan()
        #expect(rig.tabs.existingView(key) === view, "the quick-switch grace must keep the page")
        rig.elapsed += .seconds(2)
        rig.hibernation.replan()
        await rig.settle { rig.tabs.existingView(key) == nil }
        #expect(rig.tabs.existingView(key) == nil)
        #expect(rig.tabs.existingView("tab_new_2") != nil)
        #expect(rig.tabs.existingView("tab_new_3") != nil)
        #expect(rig.tabs.launchImages.take(key, appearance: .aqua) != nil)
        #expect(try #require(rig.tabs.view(for: key)).model.newTab?.cwd == "/tmp/hibernation-newtab")
    }

    @Test(arguments: ["edited", "draft", "remote", "session", "pinned", "visible", "disabled"])
    func aPageWithUserStateOrAnExemptionStaysLoaded(reason: String) async throws {
        let rig = rig()
        defer { rig.window.closeAfterTest() }
        let key = "tab_kept"
        var context = AgentPaneNewTab(kind: .agent)
        if reason == "draft" { context.draft = "unsent prompt" }
        let view = try hiddenNewTab(key, in: rig, context: context)
        if reason == "edited" { _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "newTab.touched"])) }
        if reason == "remote" { view.model.remoteChat = true }
        if reason == "session" { rig.tabs.sessions[key] = "existing-session" }
        if reason == "pinned" { rig.hibernation.isPinned = { $0 == key } }
        if reason == "visible" {
            rig.rendering.insert(key)
            rig.hibernation.sync { rig.rendering.contains($0) }
        }
        if reason == "disabled" { rig.hibernation.update(setting: BrowserHibernationSetting(mode: .off), pressure: .normal) }
        try overflow(rig)
        rig.advance(minutes: 120)
        #expect(rig.tabs.existingView(key) === view)
    }

    @Test func pageOwnedStateDefersReleaseAndTheRetryRechecksBeforeDisplacing() async throws {
        let rig = rig()
        defer { rig.window.closeAfterTest() }
        let key = "tab_held"
        let view = try hiddenNewTab(key, in: rig)
        var reads = 0
        rig.hibernation.wakeState = { _ in reads += 1; return AgentPaneWakeState(holdsPageState: reads == 1) }
        try overflow(rig)
        rig.elapsed += .seconds(11)
        rig.hibernation.replan()
        await rig.settle { reads == 1 && rig.hibernation.hasDeadline }
        #expect(rig.tabs.existingView(key) === view)
        #expect(rig.displaced.isEmpty)
        rig.elapsed += .seconds(AgentPageHibernation.keptRecheck + 1)
        rig.hibernation.replan()
        await rig.settle { rig.tabs.existingView(key) == nil }
        #expect(reads == 2)
        #expect(rig.tabs.existingView(key) == nil)
    }

    @Test func editingWhileTheWakeStateIsReadCancelsThePendingRelease() async throws {
        let rig = rig()
        defer { rig.window.closeAfterTest() }
        let key = "tab_race"
        let view = try hiddenNewTab(key, in: rig)
        var reads = 0
        rig.hibernation.wakeState = { page in
            reads += 1
            _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "newTab.touched"]))
            return AgentPaneWakeState()
        }
        try overflow(rig)
        rig.elapsed += .seconds(11)
        rig.hibernation.replan()
        await rig.settle { reads > 0 }
        #expect(rig.tabs.existingView(key) === view)
        #expect(rig.displaced.isEmpty)
    }

    @Test func hiddenChatsRetainTheirExistingDefaultEvenUnderMemoryPressure() throws {
        let rig = rig()
        defer { rig.window.closeAfterTest() }
        let chat = try rig.hiddenChat("tab_chat", session: "same-session")
        rig.hibernation.update(setting: .fallback, pressure: .critical)
        rig.advance(minutes: 120)
        #expect(rig.tabs.existingView("tab_chat") === chat)
        #expect(rig.hibernation.keepsPage("tab_chat") == .keepsState)
    }
}
