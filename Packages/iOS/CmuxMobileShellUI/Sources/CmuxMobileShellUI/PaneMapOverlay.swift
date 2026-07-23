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
    let fetchPreviews: ([String], [String]) async -> [String: MobileTerminalRenderGridFrame]
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let dismiss: () -> Void

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
        fetchPreviews: @escaping ([String], [String]) async -> [String: MobileTerminalRenderGridFrame],
        selectTerminal: @escaping (MobileTerminalPreview.ID) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.value = value
        self.terminalTheme = terminalTheme
        self.zoomNamespace = zoomNamespace
        self.isVisible = isVisible
        self.fetchPreviews = fetchPreviews
        self.selectTerminal = selectTerminal
        self.dismiss = dismiss
        _selectedSurfaceIDsByPaneID = State(initialValue: value.initialSurfaceIDsByPaneID)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneMapHeader(
                workspaceName: value.workspaceName,
                countSubtitle: countSubtitle,
                isRefreshing: isRefreshing,
                terminalTheme: terminalTheme,
                refresh: startPreviewRefresh,
                dismiss: dismissPaneMap
            )
            PaneMapCollectionView(
                items: collectionItems,
                layout: value.layout,
                terminalTheme: terminalTheme,
                zoomNamespace: zoomNamespace,
                overflowLabels: overflowLabels,
                selectPreviewSurface: selectPreviewSurface,
                jumpToTerminal: jumpToTerminal
            )
        }
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

    private var countSubtitle: String {
        let paneCount = value.panes.count
        let tabCount = value.tabCount
        switch (paneCount == 1, tabCount == 1) {
        case (true, true):
            return L10n.string(
                "mobile.paneMap.count.onePane.oneTab",
                defaultValue: "1 pane · 1 tab"
            )
        case (true, false):
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.paneMap.count.onePane.otherTabs",
                    defaultValue: "1 pane · %d tabs"
                ),
                tabCount
            )
        case (false, true):
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.paneMap.count.otherPanes.oneTab",
                    defaultValue: "%d panes · 1 tab"
                ),
                paneCount
            )
        case (false, false):
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.paneMap.count.otherPanes.otherTabs",
                    defaultValue: "%d panes · %d tabs"
                ),
                paneCount,
                tabCount
            )
        }
    }

    private func selectPreviewSurface(paneID: String, surfaceID: String) {
        selectedSurfaceIDsByPaneID[paneID] = surfaceID
    }

    private func jumpToTerminal(_ surfaceID: String) {
        selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
    }

    private func dismissPaneMap() {
        dismiss()
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
    }

    private func refreshAllPreviews(generation: UUID) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
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

private struct PaneMapHeader: View {
    let workspaceName: String
    let countSubtitle: String
    let isRefreshing: Bool
    let terminalTheme: TerminalTheme
    let refresh: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspaceName)
                    .font(.headline)
                    .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
                    .lineLimit(1)
                Text(countSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(terminalTheme.terminalChromeForegroundColor.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: refresh) {
                HStack(spacing: 5) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(terminalTheme.terminalChromeForegroundColor)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(L10n.string("mobile.paneMap.refresh", defaultValue: "Refresh"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .mobileGlassPill()
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            .accessibilityLabel(L10n.string("mobile.paneMap.refresh", defaultValue: "Refresh"))
            .accessibilityIdentifier("MobilePaneMapRefresh")

            Button(action: dismiss) {
                Text(L10n.string("mobile.paneMap.done", defaultValue: "Done"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .mobileGlassPill()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("mobile.paneMap.done", defaultValue: "Done"))
            .accessibilityIdentifier("MobilePaneMapDone")
        }
        .padding(16)
    }
}
