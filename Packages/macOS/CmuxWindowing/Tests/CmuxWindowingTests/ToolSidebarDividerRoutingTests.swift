import CoreGraphics
import Testing
@testable import CmuxWindowing

@Suite("Tool sidebar divider routing")
struct ToolSidebarDividerRoutingTests {
    private struct Portal {
        let frame: CGRect
        let isDock: Bool
    }

    /// Verifies the workspace leading edge defines the divider with or without workspace chrome.
    @Test(arguments: [CGFloat(220), CGFloat(0)])
    func workspaceLeadingEdgeDefinesDivider(workspaceSidebarWidth: CGFloat) {
        let routing = ToolSidebarDividerRouting(minimumVisibleContentWidth: 24)
        let toolWidth: CGFloat = 280
        let dividerX = workspaceSidebarWidth + toolWidth
        let portals = [
            Portal(frame: CGRect(x: workspaceSidebarWidth, y: 0, width: toolWidth, height: 800), isDock: true),
            Portal(frame: CGRect(x: dividerX, y: 0, width: 1_200 - dividerX, height: 800), isDock: false),
        ]

        #expect(
            routing.leftDividerX(
                in: portals,
                bounds: CGRect(x: 0, y: 0, width: 1_200, height: 800),
                frame: \.frame,
                isDock: \.isDock
            ) == dividerX
        )
    }

    /// Verifies Dock geometry supplies a fallback divider during transient layout churn.
    @Test func dockTrailingEdgeIsFallbackDuringWorkspaceLayoutChurn() {
        let routing = ToolSidebarDividerRouting(minimumVisibleContentWidth: 24)
        let portals = [
            Portal(frame: CGRect(x: 220, y: 0, width: 280, height: 800), isDock: true),
            Portal(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800), isDock: false),
        ]

        #expect(
            routing.leftDividerX(
                in: portals,
                bounds: CGRect(x: 0, y: 0, width: 1_200, height: 800),
                frame: \.frame,
                isDock: \.isDock
            ) == 500
        )
    }
}
