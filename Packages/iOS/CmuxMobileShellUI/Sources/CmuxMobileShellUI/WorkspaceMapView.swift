import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The workspace zoomed out: the Mac's real split geometry, one card per
/// pane, each with a live-ish styled miniature of its selected tab, its tab
/// pills, and agent status. Tap any pane or pill to open that surface full
/// screen; swipe down or tap close to dismiss.
struct WorkspaceMapView: View {
    let workspaceName: String
    let snapshot: SurfaceNavigatorSnapshot
    /// Open a tab full-screen (select + dismiss the map). Provided by the
    /// owner so the map stays store-free.
    let openTab: (MobileTerminalPreview.ID) -> Void
    /// One-shot styled-grid fetch for a terminal tab's miniature.
    let fetchPreview: @MainActor (MobileTerminalPreview.ID) async -> MobileTerminalRenderGridFrame?
    let dismiss: () -> Void

    @State private var previews: [MobileTerminalPreview.ID: MobileTerminalRenderGridFrame] = [:]
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 14) {
            header
            MapNodeView(
                node: snapshot.layout.root,
                snapshot: snapshot,
                previews: previews,
                openTab: openTab
            )
            .aspectRatio(16.0 / 10.5, contentMode: .fit)
            .frame(maxWidth: .infinity)
            Text(L10n.string(
                "mobile.surfaces.map.hint",
                defaultValue: "Tap a pane to open it"
            ))
            .font(.caption)
            .foregroundStyle(TerminalPalette.dimForeground.opacity(0.7))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            TerminalPalette.background
                .ignoresSafeArea()
        }
        .offset(y: max(dragOffset, 0))
        .gesture(dismissDrag)
        .task(id: previewFetchKey) { await loadPreviews() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceMap")
    }

    private var header: some View {
        HStack {
            Color.clear.frame(width: 30, height: 30)
            Spacer()
            Text(workspaceName)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(TerminalPalette.foreground)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TerminalPalette.dimForeground)
                    .frame(width: 30, height: 30)
                    .background(TerminalPalette.foreground.opacity(0.08), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("mobile.surfaces.map.close", defaultValue: "Close Map"))
            .accessibilityIdentifier("MobileWorkspaceMapClose")
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                    dismiss()
                } else {
                    withAnimation(.snappy(duration: 0.25)) {
                        dragOffset = 0
                    }
                }
            }
    }

    /// Identity for the miniature fetch: re-pull when the pane selections
    /// change (e.g. a tab was created/closed while the map is open).
    private var previewFetchKey: String {
        snapshot.layout.panes
            .compactMap { $0.selectedTab.map { tab in tab.id.rawValue } }
            .joined(separator: "|")
    }

    private func loadPreviews() async {
        let targets = snapshot.layout.panes.compactMap { pane -> MobileTerminalPreview.ID? in
            guard let tab = pane.selectedTab, tab.kind == .terminal else { return nil }
            return tab.id
        }
        // Sequential on purpose: a workspace has a handful of panes and each
        // replay is one short RPC, so miniatures pop in within a beat; the
        // task-group formulation trips the region-isolation checker.
        for target in targets {
            guard !Task.isCancelled else { return }
            if let frame = await fetchPreview(target) {
                previews[target] = frame
            }
        }
    }
}

/// Recursive geometry-true rendering of the split tree.
private struct MapNodeView: View {
    let node: MobileWorkspacePaneLayout.Node
    let snapshot: SurfaceNavigatorSnapshot
    let previews: [MobileTerminalPreview.ID: MobileTerminalRenderGridFrame]
    let openTab: (MobileTerminalPreview.ID) -> Void

    private static let dividerGap: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            switch node {
            case let .pane(pane):
                MapPaneCard(
                    pane: pane,
                    chips: snapshot.groups.first { $0.id == pane.id }?.chips ?? [],
                    isSelectedPane: snapshot.selectedPaneID == pane.id,
                    preview: pane.selectedTab.flatMap { previews[$0.id] },
                    openTab: openTab
                )
            case let .split(orientation, ratio, first, second):
                let clamped = min(max(ratio, 0.15), 0.85)
                switch orientation {
                case .horizontal:
                    HStack(spacing: Self.dividerGap) {
                        MapNodeView(node: first, snapshot: snapshot, previews: previews, openTab: openTab)
                            .frame(width: max((geometry.size.width - Self.dividerGap) * clamped, 0))
                        MapNodeView(node: second, snapshot: snapshot, previews: previews, openTab: openTab)
                    }
                case .vertical:
                    VStack(spacing: Self.dividerGap) {
                        MapNodeView(node: first, snapshot: snapshot, previews: previews, openTab: openTab)
                            .frame(height: max((geometry.size.height - Self.dividerGap) * clamped, 0))
                        MapNodeView(node: second, snapshot: snapshot, previews: previews, openTab: openTab)
                    }
                }
            }
        }
    }
}

/// One pane: miniature + footer (selected tab title, status, tab pills).
private struct MapPaneCard: View {
    let pane: MobileWorkspacePaneLayout.Pane
    let chips: [SurfaceNavigatorSnapshot.Chip]
    let isSelectedPane: Bool
    let preview: MobileTerminalRenderGridFrame?
    let openTab: (MobileTerminalPreview.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            miniature
            footer
        }
        .background(TerminalPalette.foreground.opacity(0.035))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelectedPane
                        ? TerminalPalette.foreground.opacity(0.45)
                        : TerminalPalette.foreground.opacity(0.14),
                    lineWidth: isSelectedPane ? 1.5 : 1
                )
        )
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture {
            if let tab = pane.selectedTab {
                openTab(tab.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceMapPane-\(pane.id.rawValue)")
    }

    @ViewBuilder
    private var miniature: some View {
        Group {
            if let preview {
                TerminalGridMiniatureView(frame: preview)
            } else if pane.selectedTab?.kind == .browser {
                placeholderIcon("globe")
            } else if pane.selectedTab?.kind == .other {
                placeholderIcon("square.dashed")
            } else {
                TerminalPalette.background.opacity(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func placeholderIcon(_ systemName: String) -> some View {
        ZStack {
            TerminalPalette.background.opacity(0.6)
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(TerminalPalette.dimForeground.opacity(0.6))
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if pane.tabs.count > 1 {
                tabPills
            } else if let chip = chips.first {
                statusDot(chip.status)
                Text(chip.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(TerminalPalette.dimForeground)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(TerminalPalette.foreground.opacity(0.06))
    }

    private var tabPills: some View {
        HStack(spacing: 4) {
            ForEach(chips.prefix(3)) { chip in
                Button {
                    openTab(chip.id)
                } label: {
                    HStack(spacing: 3) {
                        statusDot(chip.status)
                        Text(chip.title)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .frame(maxWidth: 84)
                    .background(
                        chip.isSelected
                            ? TerminalPalette.foreground.opacity(0.2)
                            : TerminalPalette.foreground.opacity(0.07),
                        in: .capsule
                    )
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TerminalPalette.dimForeground)
                .accessibilityIdentifier("MobileWorkspaceMapPill-\(chip.id.rawValue)")
            }
            if chips.count > 3 {
                Text(verbatim: "+\(chips.count - 3)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TerminalPalette.dimForeground.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ status: SurfaceNavigatorSnapshot.AgentStatus) -> some View {
        switch status {
        case .working:
            Circle().fill(.green).frame(width: 5, height: 5)
        case .needsInput:
            Circle().fill(.orange).frame(width: 5, height: 5)
        case .none:
            EmptyView()
        }
    }
}
