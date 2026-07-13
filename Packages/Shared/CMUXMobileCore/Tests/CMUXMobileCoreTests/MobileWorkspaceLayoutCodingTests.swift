import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobileWorkspaceLayoutCodingTests {
    @Test func recursiveLayoutRoundTripsThroughJSON() throws {
        let terminal = MobileWorkspaceTab(
            id: "terminal-1",
            name: "Build",
            kind: .terminal,
            isActive: true,
            isReady: true,
            agentStatus: .needsInput,
            hasUnread: true
        )
        let browser = MobileWorkspaceTab(
            id: "browser-1",
            name: "Docs",
            kind: .browser,
            isActive: true,
            isReady: true
        )
        let layout = MobileWorkspaceLayout(
            workspaceID: "workspace-1",
            root: .split(MobileWorkspaceSplit(
                id: "split-1",
                orientation: .horizontal,
                ratio: 0.4,
                first: .pane(MobileWorkspacePane(
                    id: "pane-left",
                    frame: MobileWorkspacePaneFrame(x: 0, y: 0, width: 0.4, height: 1),
                    tabs: [terminal]
                )),
                second: .pane(MobileWorkspacePane(
                    id: "pane-right",
                    frame: MobileWorkspacePaneFrame(x: 0.4, y: 0, width: 0.6, height: 1),
                    tabs: [browser]
                ))
            )),
            activePaneID: "pane-right"
        )

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(MobileWorkspaceLayout.self, from: data)

        #expect(decoded == layout)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["workspace_id"] as? String == "workspace-1")
        #expect(object["active_pane_id"] as? String == "pane-right")
    }
}
