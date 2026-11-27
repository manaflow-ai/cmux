import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
import CmuxNextCloud
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Leo, 2026-11-25: "and then the rendering of stuff changes? the pane itself switches over when you're in
/// cloud". A Cloud start in place from this Mac's chat keeps that chat's page: the same view (its React tree,
/// composer, transcript and scroll) carries the Cloud chat from Enter to the end. Before, `CloudStartChat.front`
/// released the Mac tab's page and the tab drew the Cloud tab's own, second page: a remount, which this fails on.
@MainActor @Suite(.serialized)
struct CloudStartKeepsOnePageTests {
    private actor CloudHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private let mac = AgentTabKey(machine: "local", key: "mac-tab")
    private let cloud = AgentTabKey(machine: "vm-1", key: "cloud-tab")

    private func page(in directory: URL) throws -> AgentPaneView {
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        return try #require(AgentPaneView(model: AgentPaneModel(host: CloudHost(), allowsTabConversion: true), source: .bundled(file)))
    }

    @Test func theMacTabsPageCarriesTheCloudChatWithNoRemount() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-one-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        let store = DaemonStore(), host = CloudHost()
        let record = AgentSessionRef(host: "registry:vm-1", session: nil, harness: "claude")
        tabs.lookupScoped = { [cloud] key in key == cloud ? (record, store) : nil }
        tabs.remoteHostScoped = { [cloud] key in key == cloud ? host : nil }
        let page = try page(in: directory)
        tabs.views[mac] = page
        defer { tabs.views[cloud] = nil; tabs.views[mac] = nil }

        #expect(CloudStartCore().keepsPage(inPlace: true, pageLive: true, cloudPageFree: true, onePaneEnv: nil))
        // The Cloud start that ran from this page holds it (AgentPaneHandOff `held`): no start or open goes.
        #expect(page.model.transport.replacements.beginSandbox(replacingOpened: true))
        #expect(!page.model.transport.replacements.sending(method: "session/new", connection: 1))
        #expect(tabs.rehomePage(from: mac, to: cloud))
        // Re-homed, the page's own start is the Cloud chat's: it goes (it was refused, cmux#55519).
        #expect(page.model.transport.replacements.sending(method: "session/new", connection: 2))
        // As `CloudStartChat.front`: the Mac tab is released and shows the Cloud chat.
        tabs.release(mac.key, machine: mac.machine)
        tabs.frontedChats.front(mac, with: .init(machine: cloud.machine, key: cloud.key, workspace: "cloud-ws"))
        defer { tabs.frontedChats.gone(mac) }

        let shown = try #require(tabs.view(for: mac.key, machine: mac.machine))
        #expect(shown === page, "the Mac tab draws a second page: a remount")
        #expect(!page.model.pageClosed, "the release closed the page it carries on")
        #expect((page.model.host as? CloudHost) === host)
        #expect(page.model.remoteChat && page.model.neverPooled)
        #expect(page.model.sessionId == nil)
    }

    @Test func theKillSwitchSwapsPagesAsBefore() {
        #expect(!CloudStartCore().keepsPage(inPlace: true, pageLive: true, cloudPageFree: true, onePaneEnv: "0"))
        #expect(!CloudStartCore().keepsPage(inPlace: true, pageLive: true, cloudPageFree: false, onePaneEnv: nil))
    }

    @Test func noCloudHostYetChangesNothing() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-one-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        let page = try page(in: directory)
        tabs.views[mac] = page
        defer { tabs.views[mac] = nil }
        #expect(!tabs.rehomePage(from: mac, to: cloud))
        #expect(tabs.views[mac] === page)
    }
}
