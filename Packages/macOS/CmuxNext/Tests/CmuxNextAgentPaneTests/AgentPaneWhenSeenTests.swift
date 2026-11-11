import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Lawrence's nightly ef384ddbc64d (2026-11-11, about 50 live agents): each turn's end computed its
/// repository's diff ahead of a diff tab (`DiffPageRuntime.warm`: a `git.status`, a full-patch
/// `git.diff` of 970 ms mean and 1.9 s at most, a sidecar child), for a chat nobody looked at too,
/// in front of the git reads of the view the person looked at. Work whose result only a person at
/// the chat uses is now owed to the chat's pane until someone can see it (``AgentPaneView/whenSeen``).
@Suite(.serialized)
@MainActor
struct AgentPaneWhenSeenTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func view() throws -> AgentPaneView {
        _ = NSApplication.shared
        return try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
    }

    /// A few turns of the main actor, for work owed to a later turn.
    private static func turns() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func aPaneNobodySeesRunsNoWorkUntilItShows() async throws {
        let view = try Self.view()
        var hidden = true
        view.shownPushes.isHidden = { _ in hidden }
        var ran: [String] = []

        // Three turns end while the chat is behind another tab.
        for turn in 1...3 { view.whenSeen("diffWarm") { ran.append("turn \(turn)") } }
        await Self.turns()
        #expect(ran.isEmpty, "a pane nobody sees ran \(ran)")

        // The person comes to the chat: one run, of the newest turn's work.
        hidden = false
        view.shownPushes.flush(view)
        #expect(ran == ["turn 3"])

        view.shownPushes.flush(view)
        #expect(ran == ["turn 3"], "the work ran again with nothing owed")
    }

    @Test func aPaneSomeoneSeesRunsTheWorkOnALaterTurn() async throws {
        let view = try Self.view()
        view.shownPushes.isHidden = { _ in false }
        var ran = 0

        view.whenSeen("diffWarm") { ran += 1 }
        #expect(ran == 0, "the work ran in the turn that asked")
        await Self.turns()
        #expect(ran == 1)
    }
}
