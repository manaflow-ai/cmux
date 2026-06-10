import Testing
@testable import CmuxAuthRuntime

@Suite struct PushMutePolicyTests {
    @Test func deliversWhenNotMuted() {
        #expect(pushShouldDeliver(workspaceId: "ws-a", muted: ["ws-b"]))
    }

    @Test func suppressesWhenMuted() {
        #expect(!pushShouldDeliver(workspaceId: "ws-a", muted: ["ws-a", "ws-b"]))
    }

    @Test func deliversWhenWorkspaceIdMissing() {
        #expect(pushShouldDeliver(workspaceId: nil, muted: ["ws-a"]))
        #expect(pushShouldDeliver(workspaceId: "", muted: ["ws-a"]))
    }

    @Test func deliversWhenNothingMuted() {
        #expect(pushShouldDeliver(workspaceId: "ws-a", muted: []))
    }
}
