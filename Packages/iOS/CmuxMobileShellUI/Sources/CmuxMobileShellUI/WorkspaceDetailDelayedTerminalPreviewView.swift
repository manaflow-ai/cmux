import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

#if os(iOS) && DEBUG

struct WorkspaceDetailDelayedTerminalPreviewView: View {
    private static let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-delayed-terminal")
    private static let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-delayed")
    private static let longWorkspaceTitle = "Extremely Long Workspace Title That Should Truncate Before Toolbar Buttons Overflow"
    private static let longTerminalTitle = "Long Agent Session Subtitle That Should Also Truncate First"

    @State private var store = MobileShellComposite(
        isSignedIn: true,
        connectionState: .connected,
        connectedHostName: "UI Test Mac",
        workspaces: initialWorkspaces
    )
    @State private var browserStore = BrowserSurfaceStore()
    @State private var browserStreamStore = BrowserStreamStore()
    @State private var simulatorStreamStore = MobileSimulatorStreamStore()
    @State private var didStartFixture = false
    @State private var themeStage = "loading"

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: {},
            showAddDevice: nil
        )
        .preferredColorScheme(Self.showsToolbarComparison ? .dark : nil)
        .environment(browserStore)
        .environment(browserStreamStore)
        .environment(simulatorStreamStore)
        .overlay(alignment: .topLeading) {
            if Self.showsThemeParitySequence {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("TerminalThemeStage-\(themeStage)")
            }
        }
        .task {
            guard !didStartFixture else { return }
            didStartFixture = true
            store.selectedWorkspaceID = Self.workspaceID
            if Self.showsToolbarComparison {
                store.seedWorkspaceToolbarPreview(
                    workspaceID: Self.workspaceID.rawValue,
                    chip: .init(filesChanged: 3, additions: 461, deletions: 65)
                )
            }
            if Self.usesRefreshingTerminalMenu {
                store.selectedTerminalID = Self.refreshingTerminalID(0)
                for generation in 1...80 {
                    try? await ContinuousClock().sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    store.replaceForegroundWorkspaceState([Self.refreshingWorkspace(generation: generation)])
                    store.selectedWorkspaceID = Self.workspaceID
                }
                return
            }

            try? await ContinuousClock().sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            let workspace = MobileWorkspacePreview(
                id: Self.workspaceID,
                name: Self.workspaceTitle,
                terminals: [
                    MobileTerminalPreview(id: Self.terminalID, name: Self.terminalTitle),
                ]
            )
            store.replaceForegroundWorkspaceState(Self.fixtureWorkspaces(workspace))
            store.selectedWorkspaceID = Self.workspaceID
            store.selectedTerminalID = Self.terminalID
            if Self.showsToolbarComparison {
                await deliverToolbarComparisonFrame()
                for _ in 0..<60 {
                    try? await ContinuousClock().sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                }
            }
            if Self.showsThemeParitySequence {
                await runThemeParitySequence()
            }
        }
    }

    private static var showsToolbarComparison: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_TOOLBAR_COMPARISON"] == "1"
    }

    private func deliverToolbarComparisonFrame() async {
        guard var frame = try? themeParityFrame(
            background: "#171717", foreground: "#e6edf3", revision: 1
        ) else { return }
        frame.rowSpans = [
            .init(row: 0, column: 0, text: "$ git diff --stat"),
            .init(row: 1, column: 0, text: "3 files changed, +461 / -65"),
        ]
        if ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_TOOLBAR_ALT_SCREEN"] == "1" {
            frame.activeScreen = .alternate
        }
        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            if store.deliverThemeParityPreviewFrame(frame) { return }
            try? await ContinuousClock().sleep(for: .milliseconds(50))
        }
    }

    private static var usesLongTitle: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_LONG_TITLE"] == "1"
    }

    private static var showsThemeParitySequence: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_THEME_PARITY_PREVIEW"] == "1"
    }

    private func runThemeParitySequence() async {
        let themes = [
            (stage: "dark", background: "#101522", foreground: "#e6edf3"),
            (stage: "light", background: "#f4f0df", foreground: "#17212b"),
            (stage: "custom", background: "#063f46", foreground: "#fff2a8"),
        ]
        for (index, fixture) in themes.enumerated() {
            guard !Task.isCancelled,
                  let frame = try? themeParityFrame(
                    background: fixture.background,
                    foreground: fixture.foreground,
                    revision: UInt64(index + 1)
                  ) else { return }
            while !store.deliverThemeParityPreviewFrame(frame) {
                guard !Task.isCancelled else { return }
                await Task.yield()
            }
            themeStage = fixture.stage
            if fixture.stage != themes.last?.stage {
                try? await ContinuousClock().sleep(for: .seconds(5))
            }
        }
    }

    private func themeParityFrame(
        background: String,
        foreground: String,
        revision: UInt64
    ) throws -> MobileTerminalRenderGridFrame {
        let theme = themeParityTheme(background: background, foreground: foreground)
        return try MobileTerminalRenderGridFrame(
            surfaceID: Self.terminalID.rawValue,
            stateSeq: 1,
            columns: 40,
            rows: 12,
            cursor: .init(row: 2, column: 2, blinking: true),
            styles: [
                .init(id: 0, foreground: foreground, background: background),
            ],
            rowSpans: [
                .init(row: 0, column: 0, text: "cmux theme parity renderer"),
                .init(row: 1, column: 0, text: "Mac full-frame theme reload"),
            ],
            terminalForeground: foreground,
            terminalBackground: background,
            terminalCursorColor: foreground,
            terminalTheme: theme,
            terminalConfigTheme: theme,
            terminalThemeRevision: revision
        )
    }

    private static var usesRefreshingTerminalMenu: Bool {
        UITestConfig.workspaceDetailRefreshingTerminalMenuPreviewEnabled
    }

    private static var workspaceTitle: String {
        usesLongTitle ? longWorkspaceTitle : (showsToolbarComparison ? "wlist-profile-27" : "New Workspace")
    }

    private static var terminalTitle: String {
        usesLongTitle ? longTerminalTitle : (showsToolbarComparison ? "abdulazizalbahar@MacBook-Pro" : "Terminal 1")
    }

    private static var initialWorkspaces: [MobileWorkspacePreview] {
        if usesRefreshingTerminalMenu {
            return [refreshingWorkspace(generation: 0)]
        }
        return fixtureWorkspaces(MobileWorkspacePreview(
            id: workspaceID,
            name: workspaceTitle,
            terminals: []
        ))
    }

    private static func fixtureWorkspaces(_ workspace: MobileWorkspacePreview) -> [MobileWorkspacePreview] {
        guard ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_TOOLBAR_UNREAD"] == "1" else {
            return [workspace]
        }
        return [workspace, MobileWorkspacePreview(
            id: "workspace-unread",
            name: "Unread workspace",
            hasUnread: true,
            unreadCount: 1,
            terminals: []
        )]
    }

    private static func refreshingWorkspace(generation: Int) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: workspaceID,
            name: "Terminal refresh fixture",
            terminals: (0...24).map { index in
                let baseName = index == 0 ? "Build" : String(format: "Terminal %02d", index)
                return MobileTerminalPreview(
                    id: refreshingTerminalID(index),
                    name: "\(baseName) refresh \(generation)"
                )
            }
        )
    }

    private static func refreshingTerminalID(_ index: Int) -> MobileTerminalPreview.ID {
        index == 0 ? "terminal-build" : MobileTerminalPreview.ID(rawValue: "terminal-extra-\(index)")
    }

}

// lint:allow free-function — pure DEBUG fixture factory with no production dependencies.
private func themeParityTheme(background: String, foreground: String) -> TerminalTheme {
    var theme = TerminalTheme.monokai
    theme.background = background
    theme.foreground = foreground
    return theme
}
#endif
