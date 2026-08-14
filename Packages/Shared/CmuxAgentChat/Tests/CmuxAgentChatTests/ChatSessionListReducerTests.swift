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
        state: ChatAgentState = ChatSessionListReducerTests.working,
        version: Int = 0
    ) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id, agentKind: .claude, workspaceID: workspace,
            terminalID: id, state: state, version: version
        )
    }

    @Test("a descriptorChanged for a new session is appended (toggle appears live)")
    func appendsNewSession() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let frame = ChatSessionEventFrame(
            sessionID: "s1", event: .descriptorChanged(descriptor("s1"))
        )
        let result = reducer.applying(frame, to: [])
        #expect(result.map(\.id) == ["s1"])
        #expect(result.first?.state == Self.working)
    }

    @Test("a descriptorChanged for an existing session replaces it in place")
    func replacesExisting() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
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
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let frame = ChatSessionEventFrame(
            sessionID: "s9", event: .descriptorChanged(descriptor("s9", workspace: "ws-2"))
        )
        #expect(reducer.applying(frame, to: []).isEmpty)
    }

    @Test("a nil-workspace reducer accepts every workspace")
    func nilWorkspaceAcceptsAll() {
        var reducer = ChatSessionListReducer(workspaceID: nil)
        let frame = ChatSessionEventFrame(
            sessionID: "s9", event: .descriptorChanged(descriptor("s9", workspace: "ws-2"))
        )
        #expect(reducer.applying(frame, to: []).map(\.id) == ["s9"])
    }

    @Test("an unversioned stateChanged never mutates the list (descriptorChanged is authoritative)")
    func stateChangedIsNoOpForList() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1", state: Self.working)]
        // The host pairs every transition with a versioned descriptorChanged, so
        // the bare stateChanged must not touch the list (it carries no version
        // and would otherwise be a clobber vector).
        let frame = ChatSessionEventFrame(sessionID: "s1", event: .stateChanged(.ended))
        #expect(reducer.applying(frame, to: seed) == seed)
    }

    @Test("a reordered stateChanged cannot regress newer descriptor state (clobber guard)")
    func stateChangedDoesNotClobberNewerDescriptor() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        func desc(_ state: ChatAgentState, _ version: Int) -> ChatSessionDescriptor {
            ChatSessionDescriptor(
                id: "s1", agentKind: .codex, workspaceID: "ws-1",
                terminalID: "s1", state: state, version: version
            )
        }
        // The list has the newest state (ended, v7) from a versioned descriptor.
        let seed = [desc(.ended, 7)]
        // A late, reordered bare stateChanged(working) arrives. Before this fix
        // it overwrote the row back to working with the stale version; now it is
        // ignored, so the ended (read-only) state the list authoritatively holds
        // survives.
        let stale = ChatSessionEventFrame(sessionID: "s1", event: .stateChanged(Self.working))
        let result = reducer.applying(stale, to: seed)
        #expect(result.first?.state == .ended)
        #expect(result.first?.version == 7)
    }

    @Test("a stateChanged for an unknown session never inserts")
    func stateChangedNoInsert() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let frame = ChatSessionEventFrame(sessionID: "ghost", event: .stateChanged(Self.working))
        #expect(reducer.applying(frame, to: []).isEmpty)
    }

    @Test("a sessionRemoved frame removes the matching row")
    func sessionRemovedDeletesRow() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1", version: 4), descriptor("s2")]
        let frame = ChatSessionEventFrame(sessionID: "s1", event: .sessionRemoved(version: 5))
        #expect(reducer.applying(frame, to: seed).map(\.id) == ["s2"])
    }

    @Test("a stale descriptor after sessionRemoved cannot resurrect the row")
    func sessionRemovedTombstonesStaleDescriptor() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1", version: 4)]
        let removed = ChatSessionEventFrame(sessionID: "s1", event: .sessionRemoved(version: 5))
        let stale = ChatSessionEventFrame(sessionID: "s1", event: .descriptorChanged(descriptor("s1", version: 4)))
        let afterRemoval = reducer.applying(removed, to: seed)
        #expect(afterRemoval.isEmpty)
        #expect(reducer.applying(stale, to: afterRemoval).isEmpty)
    }

    @Test("a newer descriptor after sessionRemoved can re-add the row")
    func newerDescriptorClearsRemovalTombstone() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1", version: 4)]
        let removed = ChatSessionEventFrame(sessionID: "s1", event: .sessionRemoved(version: 5))
        let newer = ChatSessionEventFrame(sessionID: "s1", event: .descriptorChanged(descriptor("s1", version: 6)))
        let afterRemoval = reducer.applying(removed, to: seed)
        #expect(reducer.applying(newer, to: afterRemoval).map(\.id) == ["s1"])
    }

    @Test("an unversioned sessionRemoved deletes without permanently tombstoning")
    func unversionedSessionRemovedDoesNotTombstoneFutureDescriptors() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1", version: 4)]
        let removed = ChatSessionEventFrame(sessionID: "s1", event: .sessionRemoved(version: Int.max))
        let replacement = ChatSessionEventFrame(sessionID: "s1", event: .descriptorChanged(descriptor("s1", version: 4)))
        let afterRemoval = reducer.applying(removed, to: seed)
        #expect(afterRemoval.isEmpty)
        #expect(reducer.applying(replacement, to: afterRemoval).map(\.id) == ["s1"])
    }

    @Test("a versioned sessionRemoved for an unknown row tombstones stale descriptors")
    func unknownVersionedSessionRemovedTombstonesFutureStaleDescriptors() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let removed = ChatSessionEventFrame(sessionID: "s1", event: .sessionRemoved(version: 5))
        let stale = ChatSessionEventFrame(
            sessionID: "s1",
            event: .descriptorChanged(descriptor("s1", version: 4))
        )
        let newer = ChatSessionEventFrame(
            sessionID: "s1",
            event: .descriptorChanged(descriptor("s1", version: 6))
        )
        let afterRemoval = reducer.applying(removed, to: [])
        #expect(afterRemoval.isEmpty)
        #expect(reducer.applying(stale, to: afterRemoval).isEmpty)
        #expect(reducer.applying(newer, to: afterRemoval).map(\.id) == ["s1"])
    }

    @Test("an unversioned sessionRemoved for an unknown row does not tombstone future descriptors")
    func unknownUnversionedSessionRemovedDoesNotTombstoneFutureDescriptors() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let removed = ChatSessionEventFrame(sessionID: "s1", event: .sessionRemoved(version: Int.max))
        let descriptor = ChatSessionEventFrame(
            sessionID: "s1",
            event: .descriptorChanged(descriptor("s1", version: 4))
        )
        let afterRemoval = reducer.applying(removed, to: [])
        #expect(afterRemoval.isEmpty)
        #expect(reducer.applying(descriptor, to: afterRemoval).map(\.id) == ["s1"])
    }

    @Test("transcript-content frames leave the list untouched")
    func ignoresContentFrames() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        let seed = [descriptor("s1")]
        let frames: [ChatSessionEvent] = [.appended([]), .updated([]), .reset, .unknown("x")]
        for event in frames {
            let frame = ChatSessionEventFrame(sessionID: "s1", event: event)
            #expect(reducer.applying(frame, to: seed) == seed)
        }
    }

    @Test("a frame that races the seed converges (idempotent upsert)")
    func idempotentUpsert() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        // The seed already contains s1; the racing descriptorChanged for the
        // same session must not duplicate it.
        let seed = [descriptor("s1", state: Self.working)]
        let frame = ChatSessionEventFrame(
            sessionID: "s1", event: .descriptorChanged(descriptor("s1", state: Self.working))
        )
        #expect(reducer.applying(frame, to: seed).count == 1)
    }

    @Test("a lower-version descriptorChanged is dropped; a higher one applies")
    func versionGatedUpsert() {
        var reducer = ChatSessionListReducer(workspaceID: "ws-1")
        func desc(_ state: ChatAgentState, _ version: Int) -> ChatSessionDescriptor {
            ChatSessionDescriptor(
                id: "s1", agentKind: .claude, workspaceID: "ws-1",
                terminalID: "s1", state: state, version: version
            )
        }
        // Seed at version 5 (working).
        let seed = [desc(Self.working, 5)]
        // A stale push (version 3, idle) arrives out of order and is dropped:
        // the newer working state the client already holds must survive.
        let stale = ChatSessionEventFrame(sessionID: "s1", event: .descriptorChanged(desc(.idle, 3)))
        let afterStale = reducer.applying(stale, to: seed)
        #expect(afterStale.first?.state == Self.working)
        #expect(afterStale.first?.version == 5)
        // A newer push (version 6, ended) applies.
        let newer = ChatSessionEventFrame(sessionID: "s1", event: .descriptorChanged(desc(.ended, 6)))
        let afterNewer = reducer.applying(newer, to: afterStale)
        #expect(afterNewer.first?.state == .ended)
        #expect(afterNewer.first?.version == 6)
    }
}
