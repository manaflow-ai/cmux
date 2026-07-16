#if DEBUG
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI

#Preview("Pane Rack — 3 panes") {
    PaneRackView(
        snapshot: .previewThreePane,
        tails: .previewPaneRackTails,
        theme: .monokai,
        actions: .preview
    ) {
        TerminalTheme.monokai.terminalBackgroundColor
    }
}

#Preview("Pane Rack — needs input") {
    PaneRackView(
        snapshot: .previewNeedsInput,
        tails: .previewPaneRackTails,
        theme: .monokai,
        actions: .preview
    ) {
        TerminalTheme.monokai.terminalBackgroundColor
    }
}

#Preview("Pane Rack — micro") {
    PaneRackView(
        snapshot: .previewThreePane,
        tails: .previewPaneRackTails,
        theme: .monokai,
        actions: .preview
    ) {
        TerminalTheme.monokai.terminalBackgroundColor
    }
    .environment(\.verticalSizeClass, .compact)
}

private extension PaneRackActions {
    static var preview: Self {
        Self(
            stagePane: { _ in },
            selectTab: { _, _ in },
            createTab: { _ in .success(()) },
            closeTab: { _ in .success(()) },
            setTailInterest: { _ in },
            setPeekBudget: { _, _ in }
        )
    }
}

private extension PaneRackSnapshot {
    static var previewThreePane: Self {
        Self(
            workspaceID: .init(rawValue: "preview-workspace"),
            panes: previewPanes,
            stagedPaneID: "pane-a",
            canCloseTabs: true
        )
    }

    static var previewNeedsInput: Self {
        Self(
            workspaceID: .init(rawValue: "preview-workspace"),
            panes: previewPanes,
            stagedPaneID: "pane-c",
            canCloseTabs: true
        )
    }

    static var previewPanes: [PaneRackPaneSnapshot] {
        [
            PaneRackPaneSnapshot(
                id: "pane-a",
                rect: .init(x: 0, y: 0, w: 0.62, h: 1),
                isMacFocused: true,
                selectedTabID: .init(rawValue: "claude"),
                tabs: [
                    .init(id: .init(rawValue: "claude"), title: "claude", isReady: true, isMacFocused: true, agentState: .working),
                    .init(id: .init(rawValue: "tests"), title: "tests", isReady: true, isMacFocused: false, agentState: .idle),
                ]
            ),
            PaneRackPaneSnapshot(
                id: "pane-b",
                rect: .init(x: 0.62, y: 0, w: 0.38, h: 0.52),
                isMacFocused: false,
                selectedTabID: .init(rawValue: "build"),
                tabs: [
                    .init(id: .init(rawValue: "build"), title: "build", isReady: true, isMacFocused: false, agentState: .working),
                ]
            ),
            PaneRackPaneSnapshot(
                id: "pane-c",
                rect: .init(x: 0.62, y: 0.52, w: 0.38, h: 0.48),
                isMacFocused: false,
                selectedTabID: .init(rawValue: "review"),
                tabs: [
                    .init(id: .init(rawValue: "review"), title: "review", isReady: true, isMacFocused: false, agentState: .needsInput),
                    .init(id: .init(rawValue: "logs"), title: "logs", isReady: true, isMacFocused: false, agentState: .idle),
                    .init(id: .init(rawValue: "server"), title: "server", isReady: true, isMacFocused: false, agentState: .ended),
                ]
            ),
        ]
    }
}

private extension Dictionary where Key == String, Value == PaneTail {
    static var previewPaneRackTails: Self {
        [
            "claude": .init(rows: ["Inspecting workspace state…", "Implementing Pane Rack"], lastActivityAt: .now, columns: 80),
            "build": .init(rows: ["swift build", "Compiling CmuxMobileShellUI"], lastActivityAt: .now, columns: 96),
            "review": .init(rows: ["Permission required", "Approve command?"], lastActivityAt: .now, columns: 72),
            "logs": .init(rows: ["server ready"], lastActivityAt: nil, columns: 100),
            "server": .init(rows: ["process exited"], lastActivityAt: nil, columns: 100),
            "tests": .init(rows: ["All tests passed"], lastActivityAt: nil, columns: 80),
        ]
    }
}
#endif
