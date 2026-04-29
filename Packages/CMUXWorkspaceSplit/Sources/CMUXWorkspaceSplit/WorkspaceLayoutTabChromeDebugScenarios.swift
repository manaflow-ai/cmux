import AppKit
import SwiftUI

@MainActor
func workspaceLayoutTabChromeDebugScenarios() -> [WorkspaceLayoutTabChromeDebugScenario] {
    let baseAppearance = workspaceLayoutTabChromeDebugAppearance()
    let terminalTab = WorkspaceLayout.Tab.rendered(
        title: "~/fun/cmuxterm-hq",
        icon: "terminal.fill",
        kind: .terminal
    )

    let scenarios = [
        WorkspaceLayoutTabChromeDebugScenario(
            id: "selected-idle",
            title: "Selected Idle",
            tab: terminalTab,
            isSelected: true,
            isHovered: false,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "selected-close-hover",
            title: "Selected Close Hover",
            tab: terminalTab,
            isSelected: true,
            isHovered: false,
            isCloseHovered: true,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "selected-close-pressed",
            title: "Selected Close Pressed",
            tab: terminalTab,
            isSelected: true,
            isHovered: false,
            isCloseHovered: true,
            isClosePressed: true,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "unselected-idle",
            title: "Unselected Idle",
            tab: terminalTab,
            isSelected: false,
            isHovered: false,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "unselected-hover",
            title: "Unselected Hover",
            tab: terminalTab,
            isSelected: false,
            isHovered: true,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "unselected-close-hover",
            title: "Unselected Close Hover",
            tab: terminalTab,
            isSelected: false,
            isHovered: true,
            isCloseHovered: true,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "dirty-unread",
            title: "Dirty + Unread",
            tab: WorkspaceLayout.Tab.rendered(
                title: "~/fun/cmuxterm-hq",
                icon: "terminal.fill",
                kind: .terminal,
                isDirty: true,
                showsNotificationBadge: true
            ),
            isSelected: false,
            isHovered: false,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "pinned",
            title: "Pinned",
            tab: WorkspaceLayout.Tab.rendered(
                title: "Pinned shell",
                icon: "terminal.fill",
                kind: .terminal,
                isPinned: true
            ),
            isSelected: false,
            isHovered: false,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "zoomed",
            title: "Zoomed",
            tab: terminalTab,
            isSelected: true,
            isHovered: false,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: true,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "loading",
            title: "Loading",
            tab: WorkspaceLayout.Tab.rendered(
                title: "Loading shell",
                icon: "terminal.fill",
                kind: .terminal,
                isLoading: true
            ),
            isSelected: true,
            isHovered: false,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
        WorkspaceLayoutTabChromeDebugScenario(
            id: "long-title",
            title: "Long Title",
            tab: WorkspaceLayout.Tab.rendered(
                title: "lawrence@Mac:~/fun/cmuxterm-hq",
                icon: "terminal.fill",
                kind: .terminal
            ),
            isSelected: true,
            isHovered: false,
            isCloseHovered: false,
            isClosePressed: false,
            showsZoomIndicator: false,
            isZoomHovered: false,
            isZoomPressed: false,
            appearance: baseAppearance
        ),
    ]

#if DEBUG
    let environment = ProcessInfo.processInfo.environment
    if let rawFilter = environment["CMUX_WORKSPACE_TAB_CHROME_SCENARIO_IDS"]?
        .split(separator: ",")
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .filter({ !$0.isEmpty }),
       !rawFilter.isEmpty {
        let allowed = Set(rawFilter)
        return scenarios.filter { allowed.contains($0.id) }
    }
#endif

    return scenarios
}

@MainActor
func workspaceLayoutTabChromeDebugAppearance() -> WorkspaceLayoutConfiguration.Appearance {
    WorkspaceLayoutConfiguration.Appearance(
        chromeColors: .init(
            backgroundHex: "#111111"
        )
    )
}
