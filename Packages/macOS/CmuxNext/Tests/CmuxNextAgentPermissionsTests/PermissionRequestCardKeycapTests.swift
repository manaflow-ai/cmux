import AppKit
@testable import CmuxNextAgentPermissions
import Testing

/// The permission card's Deny and Continue draw their keys (Escape, Return) as the keycaps every cmux dialog card
/// draws (Lawrence 2026-11-17, "match all modern parts of our cmux dialogs"), not as text glyphs after the title.
@MainActor @Suite struct PermissionRequestCardKeycapTests {
    static func views(under root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + views(under: $0) } }

    @Test func denyAndContinueDrawKeycaps() {
        let card = PermissionRequestCardView(actions: .init(deny: {}, proceed: {}, close: {}), appURL: { _ in nil })
        let request = PermissionRequest(kind: .fullDiskAccess, reason: "Read the logs", prompt: "check the logs",
                                        requester: PermissionRequester(agentName: "Claude Code", agentID: "term_a", workspaceName: "Logs"))
        card.render(PendingPermissionRequest(id: "perm_1", request: request), waiting: 0)
        let ids = Set(Self.views(under: card).compactMap { $0.identifier?.rawValue })
        #expect(ids.contains("cmux.dialog.keycap.deny"))
        #expect(ids.contains("cmux.dialog.keycap.continue"))
    }
}
