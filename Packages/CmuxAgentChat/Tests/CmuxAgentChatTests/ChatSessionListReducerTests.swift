import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Chat session list reducer")
struct ChatSessionListReducerTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let working = ChatAgentState.working(since: t0)

    private func descriptor(
        _ id: String,
        workspace: String = "ws-1",
        state: ChatAgentState = ChatSessionListReducerTests.working
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id, agentKind: .claude, workspaceID: workspace,
            terminalID: id, state: state
        )
    }

    @Test("a descriptorChanged for a new session is appended (toggle appears live)")
    func appendsNewSession() {
        let reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let frame = ChatSessionEventFrame(
            sessionID: "s1", event: .descriptorChanged(descriptor("s1"))
        )
        let result = reducer.applying(frame, to: [])
        #expect(result.map(\.id) == ["s1"])
        #expect(result.first?.state == Self.working)
    }

    @Test("a descriptorChanged for an existing session replaces it in place")
    func replacesExisting() {
        let reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1", state: Self.working), descriptor("s2", state: .idle)]
        let frame = ChatSessionEventFrame(
            sessionID: "s1", event: .descriptorChanged(descriptor("s1", state: .needsInput(since: Self.t0)))
        )
        let result = reducer.applying(frame, to: seed)
        #expect(result.count == 2)
        #expect(result.first { $0.id == "s1" }?.state == .needsInput(since: Self.t0))
    }

    @Test("a descriptorChanged for another workspace is ignored")
    func ignoresOtherWorkspace() {
        let reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let frame = ChatSessionEventFrame(
            sessionID: "s9", event: .descriptorChanged(descriptor("s9", workspace: "ws-2"))
        )
        #expect(reducer.applying(frame, to: []).isEmpty)
    }

    @Test("a nil-workspace reducer accepts every workspace")
    func nilWorkspaceAcceptsAll() {
        let reducer = ChatSessionListReducer(workspaceID: nil)
        let frame = ChatSessionEventFrame(
            sessionID: "s9", event: .descriptorChanged(descriptor("s9", workspace: "ws-2"))
        )
        #expect(reducer.applying(frame, to: []).map(\.id) == ["s9"])
    }

    @Test("a stateChanged updates an existing session (ended -> read-only)")
    func stateChangedUpdatesExisting() {
        let reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1", state: Self.working)]
        let frame = ChatSessionEventFrame(sessionID: "s1", event: .stateChanged(.ended))
        let result = reducer.applying(frame, to: seed)
        #expect(result.first?.state == .ended)
        // identity and bindings survive the state-only fold
        #expect(result.first?.terminalID == "s1")
    }

    @Test("a stateChanged for an unknown session never inserts")
    func stateChangedNoInsert() {
        let reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let frame = ChatSessionEventFrame(sessionID: "ghost", event: .stateChanged(Self.working))
        #expect(reducer.applying(frame, to: []).isEmpty)
    }

    @Test("transcript-content frames leave the list untouched")
    func ignoresContentFrames() {
        let reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1")]
        let frames: [ChatSessionEvent] = [.appended([]), .updated([]), .reset, .unknown("x")]
        for event in frames {
            let frame = ChatSessionEventFrame(sessionID: "s1", event: event)
            #expect(reducer.applying(frame, to: seed) == seed)
        }
    }

    @Test("a frame that races the seed converges (idempotent upsert)")
    func idempotentUpsert() {
        let reducer = ChatSessionListReducer(workspaceID: "ws-1")
        // The seed already contains s1; the racing descriptorChanged for the
        // same session must not duplicate it.
        let seed = [descriptor("s1", state: Self.working)]
        let frame = ChatSessionEventFrame(
            sessionID: "s1", event: .descriptorChanged(descriptor("s1", state: Self.working))
        )
        #expect(reducer.applying(frame, to: seed).count == 1)
    }
}
