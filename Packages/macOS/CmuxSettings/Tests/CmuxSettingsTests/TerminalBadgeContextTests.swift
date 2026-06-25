import Foundation
import Testing
@testable import CmuxSettings

/// Behavior of ``TerminalBadgeContext/hasIdentity``: the fail-closed signal a
/// surface uses to suppress the badge when it has no resolvable workspace/tab
/// identity, so a template's literal separators never render as a stray
/// watermark with nothing behind them.
@Suite("TerminalBadgeContext.hasIdentity")
struct TerminalBadgeContextTests {
    @Test func emptyContextHasNoIdentity() {
        // The all-nil context an unattached surface resolves to: rendering the
        // default template "{workspace} · {tab}" would otherwise leave a stray
        // " · " watermark, so callers must treat this as "hide the badge".
        #expect(TerminalBadgeContext().hasIdentity == false)
    }

    @Test func workspaceAloneHasIdentity() {
        #expect(TerminalBadgeContext(workspace: "main").hasIdentity)
    }

    @Test func tabAloneHasIdentity() {
        #expect(TerminalBadgeContext(tab: "claude").hasIdentity)
    }

    @Test func tabIndexAloneHasIdentity() {
        #expect(TerminalBadgeContext(tabIndex: 1).hasIdentity)
    }

    @Test func workspaceIndexAloneHasIdentity() {
        #expect(TerminalBadgeContext(workspaceIndex: 1).hasIdentity)
    }

    @Test func fullyPopulatedContextHasIdentity() {
        let context = TerminalBadgeContext(
            workspace: "feature/login",
            tab: "claude",
            tabIndex: 2,
            workspaceIndex: 3
        )
        #expect(context.hasIdentity)
    }
}
