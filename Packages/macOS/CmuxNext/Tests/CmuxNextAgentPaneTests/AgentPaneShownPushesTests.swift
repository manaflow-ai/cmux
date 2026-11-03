import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// "im at 100% cpu rn" (Leo, 2026-11-03): 11% of the NIGHTLY's main thread was DevTools
/// `Runtime.evaluate` calls of the agent pages' host pushes. The Chats feed set every agent pane's
/// device chats on each change of the chat index, a few per turn while agents ran, and each pane's
/// page got its own evaluate, hidden or not. A pane's app-wide state pushes now go once per turn,
/// and a pane nobody can see gets them when it shows (``AgentPaneShownPushes``).
@Suite(.serialized)
@MainActor
struct AgentPaneShownPushesTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func view() throws -> AgentPaneView {
        _ = NSApplication.shared
        return try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
    }

    private static func chats(_ index: Int) -> [AgentPaneDeviceChat] {
        [AgentPaneDeviceChat(key: "claude-code:s-\(index)", harness: "claude-code", title: "Chat \(index)",
                             updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))]
    }

    private static func deviceChatScripts(_ scripts: [String]) -> [String] {
        scripts.filter { $0.contains("applyDeviceChats") }
    }

    /// A few turns of the main actor, for pushes owed to a later turn.
    private static func turns() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Red at base: each change evaluated a script in a pane out of any window.
    @Test func aPaneNobodySeesGetsNoDeviceChatPush() async throws {
        let view = try Self.view()
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }

        for index in 1...3 { view.deviceChats = Self.chats(index) }
        await Self.turns()

        #expect(Self.deviceChatScripts(scripts).isEmpty, "a pane in no window got \(Self.deviceChatScripts(scripts).count) device chat pushes")
    }
}
