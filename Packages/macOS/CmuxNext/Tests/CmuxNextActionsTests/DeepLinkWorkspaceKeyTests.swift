import CmuxNextActions
import Testing

/// A `cmux://workspace/ws_…` link opens its workspace when it names the workspace's resource id,
/// and also when it names the workspace KEY in `ws_` form: the Chief and its subagents know a
/// subagent workspace by its key (`66ec22fe-b08e-…`), which `chief peers` showed, and wrote
/// `ws_66ec22feb08e…` (Lawrence 2026-10-22: a489's link never opened). Both are 128 random bits,
/// so the key form can never name another workspace.
struct DeepLinkWorkspaceKeyTests {
    private struct Workspace: Equatable {
        let key: String
        let resourceID: String?
    }

    private let a489 = Workspace(key: "66ec22fe-b08e-4cba-b281-b51eb1633b76",
                                 resourceID: "ws_d8e2e3359e20c03d3c27ceb7f23315af")
    private let other = Workspace(key: "0f0e0d0c-0b0a-4908-8706-050403020100",
                                  resourceID: "ws_00112233445566778899aabbccddeeff")

    private func find(_ id: String, _ workspaces: [Workspace]) -> Workspace? {
        DeepLink.workspace(id, in: workspaces, resourceID: \.resourceID, key: \.key)
    }

    @Test func theResourceIDOpensItsWorkspace() {
        #expect(find("ws_d8e2e3359e20c03d3c27ceb7f23315af", [other, a489]) == a489)
    }

    @Test func theKeyInWsFormOpensItsWorkspace() {
        #expect(find("ws_66ec22feb08e4cbab281b51eb1633b76", [other, a489]) == a489)
    }

    @Test func aResourceIDWinsOverAKeyWithTheSameBits() {
        // Never in practice (both random); the link's own kind of id comes first.
        let twin = Workspace(key: "d8e2e335-9e20-c03d-3c27-ceb7f23315af", resourceID: "ws_ffffffffffffffffffffffffffffffff")
        #expect(find("ws_d8e2e3359e20c03d3c27ceb7f23315af", [twin, a489]) == a489)
    }

    @Test func aWorkspaceNoListHasStaysGone() {
        #expect(find("ws_0123456789abcdef0123456789abcdef", [other, a489]) == nil)
        #expect(find("ws_short", [other, a489]) == nil)
    }

    @Test func theKeyFormIsTheDashedLowercaseUUID() {
        #expect(DeepLink.workspaceKey(linkID: "ws_66ec22feb08e4cbab281b51eb1633b76") == "66ec22fe-b08e-4cba-b281-b51eb1633b76")
        #expect(DeepLink.workspaceKey(linkID: "ws_66EC22FEB08E4CBAB281B51EB1633B76") == nil)
        #expect(DeepLink.workspaceKey(linkID: "pane_66ec22feb08e4cbab281b51eb1633b76") == nil)
    }
}
