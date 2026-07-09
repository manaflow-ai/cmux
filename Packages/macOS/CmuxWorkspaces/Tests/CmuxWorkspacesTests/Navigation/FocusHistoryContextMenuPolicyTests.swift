import Testing
@testable import CmuxWorkspaces

@Suite("FocusHistoryContextMenuPolicy")
struct FocusHistoryContextMenuPolicyTests {
    @Test("default preview limit is the legacy 12")
    func defaultPreviewLimit() {
        #expect(FocusHistoryContextMenuPolicy().previewLimit == 12)
    }

    @Test("preview mode caps at the preview limit")
    func previewModeCaps() {
        #expect(FocusHistoryContextMenuPolicy().maxItemCount(showingFullHistory: false) == 12)
    }

    @Test("full-history mode requests no truncation")
    func fullModeUncapped() {
        #expect(FocusHistoryContextMenuPolicy().maxItemCount(showingFullHistory: true) == nil)
    }

    @Test("a custom preview limit is honored in preview mode only")
    func customLimit() {
        let policy = FocusHistoryContextMenuPolicy(previewLimit: 4)
        #expect(policy.maxItemCount(showingFullHistory: false) == 4)
        #expect(policy.maxItemCount(showingFullHistory: true) == nil)
    }
}
