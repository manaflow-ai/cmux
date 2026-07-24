import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceWindowScopeTests {
    private func workspace(_ id: String, windowID: String? = nil) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            windowID: windowID,
            name: id,
            terminals: []
        )
    }

    @Test func snapshotRequiresSingleKnownWindowForReorder() {
        #expect([
            workspace("a", windowID: "window-1"),
            workspace("b", windowID: "window-1"),
        ].hasSingleKnownWindow)
    }

    @Test func snapshotRejectsMissingWindowForReorder() {
        #expect(![
            workspace("a", windowID: "window-1"),
            workspace("b"),
        ].hasSingleKnownWindow)
    }

    @Test func snapshotRejectsMixedWindowsForReorder() {
        #expect(![
            workspace("a", windowID: "window-1"),
            workspace("b", windowID: "window-2"),
        ].hasSingleKnownWindow)
    }
}
