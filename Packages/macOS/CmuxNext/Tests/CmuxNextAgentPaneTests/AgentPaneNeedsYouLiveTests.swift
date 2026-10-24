import CmuxNextDesign
import Foundation
import Observation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// Needs you is an App Store item (`agentPane.needsYou.enabled`, off by default). Installing it
/// must reach an agent page that is already open, without a reload (Leo 2026-10-22: "the needs you
/// thingy doesnt even work yet ofc"): before, the page read it only when it was made. The Debug
/// choice `agentPane.debug.needsYou` reaches the open page the same way, and uninstalling turns
/// the page's inbox off again.
@Suite(.serialized)
@MainActor
struct AgentPaneNeedsYouLiveTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The App's settings snapshot, as Observation sees it.
    @MainActor @Observable final class Setting {
        var installed = false
    }

    /// A page like the agent page on the old host: its bridge records each Needs you push.
    static let page = """
    <html><body><script>
    window.received = [];
    window.cmuxAcpmuxBridge = { applyNeedsYou(mode) { window.received.push(mode); } };
    </script></body></html>
    """

    private func pageReceived(_ view: AgentPaneView) async -> [String] {
        let value = try? await view.webView.evaluateJavaScript("JSON.stringify(window.received ?? [])") as? String
        return value.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    }

    private func waitForLast(_ expected: String, on view: AgentPaneView) async throws -> [String] {
        var received = await pageReceived(view)
        for _ in 0..<50 where received.last != expected {
            try await Task.sleep(for: .milliseconds(100))
            received = await pageReceived(view)
        }
        return received
    }

    @Test func installingTheItemReachesAnOpenAgentPageAndUninstallingTurnsItOff() async throws {
        let store = TunableStore.shared
        let key = AgentPaneTunables.needsYou.key
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        store.set(key, nil)
        let needsYou = AgentPaneNeedsYou.shared
        let previous = needsYou.installed
        defer {
            store.set(key, nil)
            needsYou.installed = previous
        }
        let setting = Setting()
        needsYou.installed = { setting.installed }
        #expect(AgentPaneTunables.documentAttributes["needs-you"] == "off", "Needs you is on by default")

        let directory = FileManager.default.temporaryDirectory.appending(path: "needs-you-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data(Self.page.utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        // The load pushes the mode the page was made with.
        var received = try await waitForLast("off", on: view)
        #expect(received.last == "off", "the page's load never pushed applyNeedsYou(\"off\")")

        setting.installed = true
        received = try await waitForLast("pinned", on: view)
        #expect(received.last == "pinned", "the App Store item was installed, but the open page's bridge never got applyNeedsYou(\"pinned\")")
        #expect(AgentPanePageHost.currentEvents(view).filter { $0.kind == "needsYou" } == [.needsYou(.pinned)],
                "a page that loads again on the page host would not get the installed item")
        #expect(AgentPaneTunables.documentAttributes["needs-you"] == nil, "a page made now would start with the item off")

        try #require(store.set(key, .choice("compact")) == .choice("compact"), "the store refused the Debug choice")
        received = try await waitForLast("compact", on: view)
        #expect(received.last == "compact", "the Debug choice changed, but the open page's bridge never got applyNeedsYou(\"compact\")")

        setting.installed = false
        received = try await waitForLast("off", on: view)
        #expect(received.last == "off", "the App Store item was removed, but the open page kept its inbox")
    }
}
