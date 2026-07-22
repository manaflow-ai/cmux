import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Full-screen proportional map of a workspace's Mac pane layout.
struct PaneMapOverlay: View {
    let value: PaneMapValue
    let terminalTheme: TerminalTheme
    let fetchPreviews: ([String], [String]) async -> [String: MobileTerminalRenderGridFrame]
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let dismiss: () -> Void

    @State private var selectedSurfaceIDsByPaneID: [String: String]
    @State private var previewGridsBySurfaceID: [String: MobileTerminalRenderGridFrame] = [:]
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration: UUID?

    init(
        value: PaneMapValue,
        terminalTheme: TerminalTheme,
        fetchPreviews: @escaping ([String], [String]) async -> [String: MobileTerminalRenderGridFrame],
        selectTerminal: @escaping (MobileTerminalPreview.ID) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.value = value
        self.terminalTheme = terminalTheme
        self.fetchPreviews = fetchPreviews
        self.selectTerminal = selectTerminal
        self.dismiss = dismiss
        _selectedSurfaceIDsByPaneID = State(initialValue: value.initialSurfaceIDsByPaneID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            paneCanvas
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalTheme.terminalBackgroundColor.ignoresSafeArea())
        .onAppear {
            startPreviewRefresh()
        }
        .onDisappear {
            cancelPreviewRefresh()
        }
        .onChange(of: value.layout) { _, _ in
            selectedSurfaceIDsByPaneID = value.reconciledSurfaceIDs(
                current: selectedSurfaceIDsByPaneID
            )
        }
        .accessibilityIdentifier("MobilePaneMapOverlay")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value.workspaceName)
                    .font(.headline)
                    .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
                    .lineLimit(1)

                Text(countSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(terminalTheme.terminalChromeForegroundColor.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: startPreviewRefresh) {
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

            Button(action: dismissPaneMap) {
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

    private var paneCanvas: some View {
        GeometryReader { geometry in
            let canvasRect = aspectFitCanvas(in: geometry.size)
            let normalizedRects = value.layout.normalizedRects()

            ZStack(alignment: .topLeading) {
                ForEach(Array(value.panes.enumerated()), id: \.element.id) { index, pane in
                    if let normalizedRect = normalizedRects[pane.id] {
                        let tileRect = scaledTileRect(normalizedRect, in: canvasRect)
                        let surfaceID = selectedSurfaceIDsByPaneID[pane.id]

                        PaneMapTileView(
                            pane: pane,
                            paneNumber: index + 1,
                            paneCount: value.panes.count,
                            isFocusedOnMac: value.layout.focusedPaneID == pane.id,
                            terminalTheme: terminalTheme,
                            selectedSurfaceID: surfaceID,
                            phoneSelectedSurfaceID: value.phoneSelectedSurfaceID,
                            previewGrid: surfaceID.flatMap { previewGridsBySurfaceID[$0] },
                            isLoadingPreview: isRefreshing,
                            agentStateKind: surfaceID.flatMap { value.agentStateKindsBySurfaceID[$0] },
                            selectPreviewSurface: { selectedSurfaceIDsByPaneID[pane.id] = $0 },
                            jumpToTerminal: jumpToTerminal
                        )
                        .frame(width: tileRect.width, height: tileRect.height)
                        .position(x: tileRect.midX, y: tileRect.midY)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
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

    private func aspectFitCanvas(in size: CGSize) -> CGRect {
        // Fill the available space rather than forcing the Mac window's
        // landscape aspect: the split RATIOS carry the structural mental
        // model, and on a portrait phone larger tiles (more readable
        // previews) are worth more than aspect fidelity.
        CGRect(
            x: 16,
            y: 8,
            width: max(0, size.width - 32),
            height: max(0, size.height - 24)
        )
    }

    private func scaledTileRect(_ normalizedRect: CGRect, in canvasRect: CGRect) -> CGRect {
        CGRect(
            x: canvasRect.minX + normalizedRect.minX * canvasRect.width,
            y: canvasRect.minY + normalizedRect.minY * canvasRect.height,
            width: normalizedRect.width * canvasRect.width,
            height: normalizedRect.height * canvasRect.height
        )
        .insetBy(dx: 3, dy: 3)
    }

    private func jumpToTerminal(_ surfaceID: String) {
        selectTerminal(MobileTerminalPreview.ID(rawValue: surfaceID))
        dismissPaneMap()
    }

    private func dismissPaneMap() {
        cancelPreviewRefresh()
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
        let previews = await fetchPreviews(
            selectedTerminalSurfaceIDs,
            remainingTerminalSurfaceIDs
        )
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        previewGridsBySurfaceID = previews
    }
}
