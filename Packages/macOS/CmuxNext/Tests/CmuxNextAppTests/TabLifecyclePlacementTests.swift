import CmuxNextTerminal
@testable import CmuxNextApp
import Testing

/// New Terminal Tab chooses the Ghostty inheritance key for its actual placement. In particular,
/// auto-layout split placement must consult `split-inherit-working-directory`, not the tab key.
struct TabLifecyclePlacementTests {
    @Test func splitPlacementUsesSplitInheritance() {
        let kind = TabLifecycle.terminalInheritanceKind(opensWorkspace: false, asTab: false, splitPlacement: true)
        let settings = GhosttyWorkingDirectoryInheritance(window: true, tab: true, split: true)
        #expect(kind.isSplit)
        #expect(settings.inherits(kind))
    }

    @Test func splitPlacementDoesNotBecomeTabInheritanceWhenSplitIsDisabled() {
        let kind = TabLifecycle.terminalInheritanceKind(opensWorkspace: false, asTab: false, splitPlacement: true)
        let settings = GhosttyWorkingDirectoryInheritance(window: true, tab: true, split: false)
        #expect(kind.isSplit)
        #expect(!settings.inherits(kind))
    }

    @Test func workspaceAndExplicitTabPlacementsKeepTheirKeys() {
        let workspace = TabLifecycle.terminalInheritanceKind(opensWorkspace: true, asTab: false, splitPlacement: true)
        let tab = TabLifecycle.terminalInheritanceKind(opensWorkspace: false, asTab: true, splitPlacement: true)
        #expect(workspace.isWindow)
        #expect(tab.isTab)
    }
}

private extension GhosttyWorkingDirectoryInheritance.Kind {
    var isWindow: Bool {
        if case .window = self { true } else { false }
    }

    var isTab: Bool {
        if case .tab = self { true } else { false }
    }

    var isSplit: Bool {
        if case .split = self { true } else { false }
    }
}
