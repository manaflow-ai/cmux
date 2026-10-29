import AppKit
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// 2026-10-28 (handoff/cef-parent-tracker-crash.md): an agent pane was freed with its Chromium page still in it, so
/// its `close()` never ran, and AppKit's teardown aborted the app inside the CEF fork's parent tracker. Every owner
/// read in the code closes its pane first, so the one that does not is unknown. A pane freed without `close()` now
/// reports who made it (its maker, set when it is made), with no other change: the next one names the owner.
@Suite(.serialized)
@MainActor
struct AgentPaneUnclosedFreeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Reports {
        var makers: [AgentPaneMaker] = []
    }

    private static func pane(_ reports: Reports, maker: AgentPaneMaker) throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"),
                                              source: .bundled(file), webUI: .agentPaneTestHost(), gestures: .testing()))
        view.maker = maker
        view.onFreedUnclosed = { [reports] maker in reports.makers.append(maker) }
        return view
    }

    /// Lets the pane's own tasks and deadlines that hold it run out, so its last reference goes.
    private static func drain() async throws {
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func aPaneFreedWithoutCloseReportsItsMaker() async throws {
        let reports = Reports()
        weak var gone: AgentPaneView?
        do {
            let view = try Self.pane(reports, maker: .spare)
            gone = view
        }
        try await Self.drain()
        try #require(gone == nil, "the pane was not freed: the test cannot see its deinit")
        #expect(reports.makers == [.spare], "a pane freed without close() reported \(reports.makers)")
    }

    @Test func aClosedPaneReportsNothing() async throws {
        let reports = Reports()
        weak var gone: AgentPaneView?
        do {
            let view = try Self.pane(reports, maker: .tab)
            view.close()
            gone = view
        }
        try await Self.drain()
        try #require(gone == nil, "the pane was not freed: the test cannot see its deinit")
        #expect(reports.makers.isEmpty, "a closed pane reported \(reports.makers)")
    }
}
