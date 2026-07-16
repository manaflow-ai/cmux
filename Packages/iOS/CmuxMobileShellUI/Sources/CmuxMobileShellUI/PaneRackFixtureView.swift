#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Fully local host for exercising the production Pane Rack without a Mac.
struct PaneRackFixtureView: View {
    let staticTails: Bool

    @State private var snapshot = Self.initialSnapshot
    @State private var tailStore = PaneTailStore()
    @State private var nextFakeTabOrdinal = 1

    private let theme = TerminalTheme.monokai

    var body: some View {
        NavigationStack {
            PaneRackView(
                snapshot: snapshot,
                tails: tailStore.tails,
                theme: theme,
                actions: actions
            ) {
                TerminalLayoutPreviewSurface(
                    theme: theme,
                    feedContent: true,
                    transcriptName: "claude",
                    targetColumns: 76
                )
            }
            .navigationTitle("Pane Rack Fixture")
            .navigationBarTitleDisplayMode(.inline)
            .mobileTerminalNavigationChrome(theme: theme)
        }
        .task { await runTailScript() }
    }

    private var actions: PaneRackActions {
        PaneRackActions(
            stagePane: stagePane,
            selectTab: selectTab,
            createTab: createTab,
            closeTab: closeTab,
            setTailInterest: tailStore.setInterest,
            setPeekBudget: tailStore.setPeekBudget
        )
    }

    private func stagePane(_ paneID: String) {
        guard snapshot.panes.contains(where: { $0.id == paneID }) else { return }
        snapshot.stagedPaneID = paneID
    }

    private func selectTab(_ surfaceID: String, _ paneID: String) {
        guard let paneIndex = snapshot.panes.firstIndex(where: { $0.id == paneID }),
              snapshot.panes[paneIndex].tabs.contains(where: { $0.id.rawValue == surfaceID }) else {
            return
        }
        snapshot.panes[paneIndex].selectedTabID = .init(rawValue: surfaceID)
        snapshot.stagedPaneID = paneID
    }

    private func createTab(in paneID: String) async -> Result<Void, PaneRackMutationFailure> {
        guard let paneIndex = snapshot.panes.firstIndex(where: { $0.id == paneID }) else {
            return .failure(.invalidTarget)
        }
        let ordinal = nextFakeTabOrdinal
        let surfaceID = "fixture-new-\(ordinal)"
        nextFakeTabOrdinal += 1
        snapshot.panes[paneIndex].tabs.append(
            PaneRackTabSnapshot(
                id: .init(rawValue: surfaceID),
                title: "terminal \(ordinal)",
                isReady: true,
                isMacFocused: false,
                agentState: .idle
            )
        )
        snapshot.panes[paneIndex].selectedTabID = .init(rawValue: surfaceID)
        return .success(())
    }

    private func closeTab(_ surfaceID: String) async -> Result<Void, PaneRackMutationFailure> {
        guard snapshot.panes.flatMap(\.tabs).count > 1,
              let paneIndex = snapshot.panes.firstIndex(where: {
                  $0.tabs.contains(where: { $0.id.rawValue == surfaceID })
              }) else {
            return .failure(.invalidTarget)
        }
        snapshot.panes[paneIndex].tabs.removeAll { $0.id.rawValue == surfaceID }
        if snapshot.panes[paneIndex].tabs.isEmpty {
            let removedPaneID = snapshot.panes[paneIndex].id
            snapshot.panes.remove(at: paneIndex)
            if snapshot.stagedPaneID == removedPaneID, let fallback = snapshot.panes.first {
                snapshot.stagedPaneID = fallback.id
            }
        } else if snapshot.panes[paneIndex].selectedTabID?.rawValue == surfaceID {
            snapshot.panes[paneIndex].selectedTabID = snapshot.panes[paneIndex].tabs.first?.id
        }
        return .success(())
    }

    private func runTailScript() async {
        await Task.yield()
        publishTails(rotation: 0)
        guard !staticTails else { return }

        var rotation = 1
        while !Task.isCancelled {
            do {
                // This delay is the fixture's intended visible streaming cadence.
                try await ContinuousClock().sleep(for: .milliseconds(700))
            } catch {
                return
            }
            publishTails(rotation: rotation)
            rotation += 1
        }
    }

    private func publishTails(rotation: Int) {
        for (surfaceID, lines) in Self.tailLinesBySurfaceID {
            let rotated = lines.indices.map { lines[($0 + rotation) % lines.count] }
            guard let frame = try? MobileTerminalRenderGridFrame.fromPlainRows(
                surfaceID: surfaceID,
                stateSeq: UInt64(rotation + 1),
                columns: 96,
                rows: 8,
                text: rotated.suffix(3).joined(separator: "\n")
            ) else { continue }
            tailStore.apply(frame)
        }
    }

    private static let initialSnapshot = PaneRackSnapshot(
        workspaceID: "fixture-workspace",
        panes: [
            PaneRackPaneSnapshot(
                id: "pane-a",
                rect: .init(x: 0, y: 0, w: 0.62, h: 1),
                isMacFocused: true,
                selectedTabID: "claude",
                tabs: [
                    .init(id: "claude", title: "claude", isReady: true, isMacFocused: true, agentState: .working),
                    .init(id: "tests", title: "tests", isReady: true, isMacFocused: false, agentState: .idle),
                ]
            ),
            PaneRackPaneSnapshot(
                id: "pane-b",
                rect: .init(x: 0.62, y: 0, w: 0.38, h: 0.52),
                isMacFocused: false,
                selectedTabID: "build",
                tabs: [
                    .init(id: "build", title: "build", isReady: true, isMacFocused: false, agentState: .working),
                ]
            ),
            PaneRackPaneSnapshot(
                id: "pane-c",
                rect: .init(x: 0.62, y: 0.52, w: 0.38, h: 0.48),
                isMacFocused: false,
                selectedTabID: "review",
                tabs: [
                    .init(id: "review", title: "review", isReady: true, isMacFocused: false, agentState: .needsInput),
                    .init(id: "logs", title: "logs", isReady: true, isMacFocused: false, agentState: .idle),
                    .init(id: "server", title: "server", isReady: true, isMacFocused: false, agentState: .ended),
                ]
            ),
        ],
        stagedPaneID: "pane-a",
        canCloseTabs: true
    )

    private static let tailLinesBySurfaceID: [String: [String]] = [
        "claude": ["Inspecting workspace state…", "Implementing Pane Rack fixture", "Running focused checks"],
        "tests": ["swift test", "Testing PaneTailStore", "All package tests passed"],
        "build": ["Resolving package graph", "Compiling CmuxMobileShellUI", "Linking cmux.app"],
        "review": ["Reviewing staged changes", "Permission required", "Approve the close action?"],
        "logs": ["api: request completed 200", "worker: queue depth 0", "stream: client connected"],
        "server": ["Starting local preview server", "Listening on 127.0.0.1", "process exited normally"],
    ]
}
#endif
