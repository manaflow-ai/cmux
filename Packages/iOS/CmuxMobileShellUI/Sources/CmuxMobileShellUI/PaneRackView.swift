import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Snapshot-isolated Pane Rack chrome surrounding the existing terminal stage.
struct PaneRackView<StageContent: View>: View {
    let snapshot: PaneRackSnapshot
    let tails: [String: PaneTail]
    let theme: TerminalTheme
    let actions: PaneRackActions
    @ViewBuilder let stageContent: () -> StageContent

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isUnfolded = false
    @State private var pendingCloseTab: PaneRackTabSnapshot?
    @State private var toast: WorkspaceActionToastContent?

    private var presentation: PaneRackPresentation {
        PaneRackPresentation(snapshot: snapshot)
    }

    private var background: Color { theme.terminalBackgroundColor }
    private var chromeForeground: Color { theme.terminalChromeForegroundColor }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(presentation.strips) { pane in
                PaneRackStripView(
                    pane: pane,
                    paneIndex: (snapshot.panes.firstIndex(where: { $0.id == pane.id }) ?? 0) + 1,
                    allPanes: snapshot.panes,
                    tail: pane.selectedTab.flatMap { tails[$0.id.rawValue] },
                    chromeForeground: chromeForeground,
                    background: background,
                    isMicro: verticalSizeClass == .compact,
                    stage: { actions.stagePane(pane.id) },
                    setPeekBudget: { rows in
                        guard let surfaceID = pane.selectedTab?.id.rawValue else { return }
                        actions.setPeekBudget(surfaceID, rows)
                    }
                )
            }

            if presentation.showsHeader, let stagedPane = presentation.stagedPane {
                PaneRackStageHeaderView(
                    pane: stagedPane,
                    allPanes: snapshot.panes,
                    chromeForeground: chromeForeground,
                    background: background,
                    isUnfolded: isUnfolded,
                    toggleUnfold: { isUnfolded.toggle() },
                    createTab: performCreate
                )
            }

            ZStack(alignment: .top) {
                stageContent()
                    .id(presentation.stagedPane?.selectedTab?.id.rawValue ?? snapshot.stagedPaneID)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: presentation.stagedPane?.selectedTab?.id)

                if isUnfolded, let stagedPane = presentation.stagedPane {
                    Color.black.opacity(0.35)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: collapse)
                        .transition(.opacity)

                    PaneRackUnfoldView(
                        pane: stagedPane,
                        tails: tails,
                        canClose: snapshot.canCloseTabs,
                        chromeForeground: chromeForeground,
                        background: background,
                        selectTab: select,
                        requestClose: requestClose,
                        createTab: performCreate
                    )
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }

                if let toast {
                    VStack {
                        Spacer()
                        WorkspaceActionToast(content: toast) {
                            withAnimation(.snappy(duration: 0.2)) {
                                self.toast = nil
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("PaneRackToast")
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(background)
        .onAppear { actions.setTailInterest(interestedSurfaceIDs) }
        .onDisappear { actions.setTailInterest([]) }
        .onChange(of: interestedSurfaceIDs) { _, surfaceIDs in
            actions.setTailInterest(surfaceIDs)
        }
        .onChange(of: snapshot.stagedPaneID) { _, _ in
            collapse()
        }
        .confirmationDialog(
            L10n.string("mobile.paneRack.closeTab.title", defaultValue: "Close Tab"),
            isPresented: Binding(
                get: { pendingCloseTab != nil },
                set: { if !$0 { pendingCloseTab = nil } }
            ),
            presenting: pendingCloseTab
        ) { tab in
            Button(
                L10n.string("mobile.paneRack.closeTab.title", defaultValue: "Close Tab"),
                role: .destructive
            ) {
                performClose(tab)
            }
            Button(
                L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {}
        } message: { _ in
            Text(
                L10n.string(
                    "mobile.paneRack.closeTab.runningMessage",
                    defaultValue: "Close this tab? An agent is still running."
                )
            )
        }
    }

    private var interestedSurfaceIDs: Set<String> {
        presentation.interestedSurfaceIDs(isUnfolded: isUnfolded)
    }

    private func collapse() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            isUnfolded = false
        }
    }

    private func select(_ tab: PaneRackTabSnapshot) {
        guard let stagedPane = presentation.stagedPane else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            actions.selectTab(tab.id.rawValue, stagedPane.id)
            isUnfolded = false
        }
    }

    private func requestClose(_ tab: PaneRackTabSnapshot) {
        switch tab.agentState {
        case .working, .needsInput:
            pendingCloseTab = tab
        case .idle, .ended:
            performClose(tab)
        }
    }

    private func performCreate() {
        guard let stagedPane = presentation.stagedPane else { return }
        Task {
            let result = await actions.createTab(stagedPane.id)
            if case .failure = result {
                presentToast(
                    L10n.string(
                        "mobile.paneRack.create.failure",
                        defaultValue: "Couldn't create a new terminal."
                    )
                )
            }
        }
    }

    private func performClose(_ tab: PaneRackTabSnapshot) {
        pendingCloseTab = nil
        Task {
            let result = await actions.closeTab(tab.id.rawValue)
            guard case let .failure(failure) = result else { return }
            switch failure {
            case .lastTerminal:
                presentToast(
                    L10n.string(
                        "mobile.paneRack.closeTab.lastTerminal",
                        defaultValue: "The last terminal can't be closed. Close the workspace instead."
                    )
                )
            case .unsupported, .notConnected, .invalidTarget, .rejected:
                presentToast(
                    L10n.string(
                        "mobile.paneRack.closeTab.failure",
                        defaultValue: "Couldn't close this tab."
                    )
                )
            }
        }
    }

    private func presentToast(_ message: String) {
        withAnimation(.snappy(duration: 0.2)) {
            toast = WorkspaceActionToastContent(message: message)
        }
    }
}
