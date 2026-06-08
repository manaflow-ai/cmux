import Testing
@testable import CmuxAuthRuntime

@Suite struct PushMutePolicyTests {
    @Test func deliversWhenNotMuted() {
        #expect(PushMutePolicy.shouldDeliver(workspaceId: "ws-a", muted: ["ws-b"]))
    }

    @Test func suppressesWhenMuted() {
        #expect(!PushMutePolicy.shouldDeliver(workspaceId: "ws-a", muted: ["ws-a", "ws-b"]))
    }

    @Test func deliversWhenWorkspaceIdMissing() {
        #expect(PushMutePolicy.shouldDeliver(workspaceId: nil, muted: ["ws-a"]))
        #expect(PushMutePolicy.shouldDeliver(workspaceId: "", muted: ["ws-a"]))
    }

    @Test func deliversWhenNothingMuted() {
        #expect(PushMutePolicy.shouldDeliver(workspaceId: "ws-a", muted: []))
    }
}
