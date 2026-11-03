import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentPageHibernationNewTabTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func anUntouchedChromiumNewTabUsesItsNativeContextWithoutCapturingAHiddenSurface() async throws {
        let rig = AgentPageHibernationTests.Rig()
        defer { rig.window.closeAfterTest() }
        rig.hibernation.update(chatSetting: ChatPageHibernationSettings(newTabCapacity: 0))
        let folder = FileManager.default.temporaryDirectory.appending(path: "hibernation-newtab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let key = "tab_chromium_new"
        let context = AgentPaneNewTab(kind: .agent, cwd: "/tmp/hibernation-newtab")
        rig.records[key] = AgentSessionRef(host: AgentPageHibernationTests.thisMac, hostName: "This Mac", harness: "claude")
        rig.tabs.newTabPages[key] = (context, NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: context), source: .bundled(file),
                                             pageHost: true, testRoot: true, chromium: hosting))
        defer { view.close() }
        await view.page?.chromiumStart?.value
        try #require(view.pageDrawsOverCovers)
        rig.tabs.views[key] = view
        var captures = 0
        rig.hibernation.snapshot = { _ in captures += 1; return nil }
        rig.hibernation.wakeState = { _ in AgentPaneWakeState() }
        rig.hibernation.pageBuilt(key)
        rig.advance(minutes: 6)
        await rig.settle { rig.tabs.existingView(key) == nil }
        #expect(rig.tabs.existingView(key) == nil, "the default cap must release the untouched Chromium New Tab")
        #expect(captures == 0, "hidden Chromium surfaces must never be captured for the New Tab cap")
        #expect(rig.tabs.newTabPages[key]?.page.cwd == context.cwd)
        #expect(rig.records[key]?.session == nil)
    }
}
