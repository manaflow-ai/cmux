import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Full-screen interactive map of a workspace's Mac pane layout.
struct PaneMapOverlay: View {
    let value: PaneMapValue
    let terminalTheme: TerminalTheme
    let zoomNamespace: Namespace.ID
    let isVisible: Bool
    let allowsReordering: Bool
    let refreshTrigger: Int
    let fetchPreviews: ([String], [String]) async -> [String: MobileTerminalRenderGridFrame]
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let reorderPanes: ([String]) async -> Bool
    let refreshingChanged: (Bool) -> Void

    @State private var selectedSurfaceIDsByPaneID: [String: String]
    @State private var previewsBySurfaceID: [String: MobileTerminalPaneMapPreview] = [:]
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration: UUID?

    init(
        value: PaneMapValue,
        terminalTheme: TerminalTheme,
        zoomNamespace: Namespace.ID,
        isVisible: Bool,
        allowsReordering: Bool,
        refreshTrigger: Int,
        fetchPreviews: @escaping ([String], [String]) async -> [String: MobileTerminalRenderGridFrame],
        selectTerminal: @escaping (MobileTerminalPreview.ID) -> Void,
        reorderPanes: @escaping ([String]) async -> Bool,
        refreshingChanged: @escaping (Bool) -> Void
    ) {
        self.value = value
        self.terminalTheme = terminalTheme
        self.zoomNamespace = zoomNamespace
        self.isVisible = isVisible
        self.allowsReordering = allowsReordering
        self.refreshTrigger = refreshTrigger
        self.fetchPreviews = fetchPreviews
        self.selectTerminal = selectTerminal
        self.reorderPanes = reorderPanes
        self.refreshingChanged = refreshingChanged
        _selectedSurfaceIDsByPaneID = State(initialValue: value.initialSurfaceIDsByPaneID)
    }

    var body: some View {
        PaneMapCollectionView(
            items: collectionItems,
            layout: value.layout,
            terminalTheme: terminalTheme,
            zoomNamespace: zoomNamespace,
            overflowLabels: overflowLabels,
            allowsReordering: allowsReordering,
            selectPreviewSurface: selectPreviewSurface,
            jumpToTerminal: jumpToTerminal,
            reorderPanes: reorderPanes
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            terminalTheme.terminalBackgroundColor
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityIdentifier("MobilePaneMapOverlay")
        }
        .onAppear {
            if isVisible {
                startPreviewRefresh()
            }
        }
        .onDisappear {
            cancelPreviewRefresh()
        }
        .onChange(of: isVisible) { _, isVisible in
            if isVisible {
                startPreviewRefresh()
            } else {
                cancelPreviewRefresh()
            }
        }
        .onChange(of: refreshTrigger) { _, _ in
            guard isVisible else { return }
            cancelPreviewRefresh()
            startPreviewRefresh()
        }
        .onChange(of: value.layout) { _, _ in
            selectedSurfaceIDsByPaneID = value.reconciledSurfaceIDs(
                current: selectedSurfaceIDsByPaneID
            )
        }
    }

    private var collectionItems: [PaneMapCollectionItem] {
        value.panes.enumerated().map { index, pane in
            let selectedSurfaceID = selectedSurfaceIDsByPaneID[pane.id]
            return PaneMapCollectionItem(
                pane: pane,
                paneNumber: index + 1,
                paneCount: value.panes.count,
                isFocusedOnMac: value.layout.focusedPaneID == pane.id,
                selectedSurfaceID: selectedSurfaceID,
                phoneSelectedSurfaceID: value.phoneSelectedSurfaceID,
                preview: selectedSurfaceID.flatMap { previewsBySurfaceID[$0] },
                isLoadingPreview: isRefreshing,
                agentStateKind: selectedSurfaceID.flatMap {
                    value.agentStateKindsBySurfaceID[$0]
                }
            )
        }
    }

    private var overflowLabels: PaneMapOverflowLabels {
        PaneMapOverflowLabels(
            leading: L10n.string(
                "mobile.paneMap.more.leading",
                defaultValue: "More panes to the left"
            ),
            trailing: L10n.string(
                "mobile.paneMap.more.trailing",
                defaultValue: "More panes to the right"
            ),
            top: L10n.string(
                "mobile.paneMap.more.top",
                defaultValue: "More panes above"
            ),
            bottom: L10n.string(
                "mobile.paneMap.more.bottom",
                defaultValue: "More panes below"
            )
        )
    }

    private func selectPreviewSurface(paneID: String, surfaceID: String) {
        selectedSurfaceIDsByPaneID[paneID] = surfaceID
    }

    private func jumpToTerminal(_ surfaceID: String) {
        selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
    }

    private func startPreviewRefresh() {
        guard refreshTask == nil else { return }
        let generation = UUID()
        refreshGeneration = generation
        refreshTask = Task {
            await refreshAllPreviews(generation: generation)
            guard refreshGeneration == generation else { return }
            refreshTask = nil
        }
    }

    private func cancelPreviewRefresh() {
        refreshGeneration = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        refreshingChanged(false)
    }

    private func refreshAllPreviews(generation: UUID) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshingChanged(true)
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
                refreshingChanged(false)
            }
        }

        let selectedTerminalSurfaceIDs = value.panes.compactMap { pane -> String? in
            guard let surfaceID = selectedSurfaceIDsByPaneID[pane.id],
                  pane.surfaces.first(where: { $0.id == surfaceID })?.type.isTerminal == true else {
                return nil
            }
            return surfaceID
        }
        let selectedSet = Set(selectedTerminalSurfaceIDs)
        let remainingTerminalSurfaceIDs = value.panes.flatMap(\.surfaces).compactMap { surface in
            surface.type.isTerminal && !selectedSet.contains(surface.id) ? surface.id : nil
        }
        let frames = await fetchPreviews(
            selectedTerminalSurfaceIDs,
            remainingTerminalSurfaceIDs
        )
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        previewsBySurfaceID = frames.mapValues { $0.paneMapPreview() }
    }
}
