#if DEBUG && os(iOS)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileShellModel
import SwiftUI

/// DEBUG fixture for `CMUX_UITEST_SURFACE_NAV_PREVIEW=1`: the surface
/// navigator (tab strip + pager + workspace map) over a deterministic fake
/// three-pane layout with synthetic terminal pages and map miniatures. No
/// sign-in, pairing, store, or streaming — pure pixels and gestures.
struct SurfaceNavigatorPreviewView: View {
    private typealias Layout = MobileWorkspacePaneLayout

    /// Fixed Monokai palette so fixture pixels are deterministic without a
    /// live theme store.
    private static let palette = SurfaceNavigatorSnapshot.Palette(
        background: Color(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0),
        foreground: Color(red: 0xF8 / 255.0, green: 0xF8 / 255.0, blue: 0xF2 / 255.0)
    )

    @State private var selectedTabID: MobileTerminalPreview.ID = "tab-agent"
    @State private var isMapPresented = false
    @State private var closedTabIDs: Set<MobileTerminalPreview.ID> = []

    private var layout: Layout {
        func tabs(_ all: [Layout.Tab]) -> [Layout.Tab] {
            all.filter { !closedTabIDs.contains($0.id) }
        }
        let leftTabs = tabs([
            Layout.Tab(id: "tab-agent", kind: .terminal, title: "claude"),
            Layout.Tab(id: "tab-shell", kind: .terminal, title: "zsh"),
        ])
        let topTabs = tabs([
            Layout.Tab(id: "tab-server", kind: .terminal, title: "bun dev"),
        ])
        let bottomTabs = tabs([
            Layout.Tab(id: "tab-preview", kind: .browser, title: "localhost:3777"),
        ])
        return Layout(
            root: .split(
                orientation: .horizontal,
                ratio: 0.58,
                first: .pane(Layout.Pane(
                    id: "pane-left",
                    tabs: leftTabs,
                    selectedTabID: leftTabs.first { $0.id == selectedTabID }?.id ?? leftTabs.first?.id
                )),
                second: .split(
                    orientation: .vertical,
                    ratio: 0.55,
                    first: .pane(Layout.Pane(
                        id: "pane-top",
                        tabs: topTabs,
                        selectedTabID: topTabs.first?.id
                    )),
                    second: .pane(Layout.Pane(
                        id: "pane-bottom",
                        tabs: bottomTabs,
                        selectedTabID: bottomTabs.first?.id
                    ))
                )
            )
        )
    }

    private var snapshot: SurfaceNavigatorSnapshot {
        let statusByTab: [MobileTerminalPreview.ID: SurfaceNavigatorSnapshot.AgentStatus] = [
            "tab-agent": .working,
            "tab-server": .needsInput,
        ]
        let groups = layout.panes.map { pane in
            SurfaceNavigatorSnapshot.PaneGroup(
                id: pane.id,
                chips: pane.tabs.map { tab in
                    SurfaceNavigatorSnapshot.Chip(
                        id: tab.id,
                        title: tab.title,
                        kind: tab.kind,
                        status: statusByTab[tab.id] ?? .none,
                        isSelected: tab.id == selectedTabID,
                        isReady: true
                    )
                }
            )
        }
        return SurfaceNavigatorSnapshot(
            groups: groups,
            selectedTabID: selectedTabID,
            layout: layout,
            canCloseTab: layout.orderedTabs.filter { $0.kind == .terminal }.count > 1,
            palette: Self.palette
        )
    }

    private var actions: SurfaceNavigatorActions {
        SurfaceNavigatorActions(
            selectTab: { selectedTabID = $0 },
            closeTab: { id in
                closedTabIDs.insert(id)
                if selectedTabID == id {
                    selectedTabID = layout.orderedTabs.first?.id ?? selectedTabID
                }
            },
            newTab: { _ in },
            openMap: { withAnimation(.snappy(duration: 0.3)) { isMapPresented = true } }
        )
    }

    var body: some View {
        let snapshot = snapshot
        VStack(spacing: 0) {
            SurfaceTabStrip(snapshot: snapshot, actions: actions)
                .background(Self.palette.background)
            SurfacePagerView(
                pageIDs: snapshot.orderedChips.map(\.id.rawValue),
                currentID: selectedTabID.rawValue,
                onPageSettled: { selectedTabID = .init(rawValue: $0) },
                page: { id, context in
                    fakePage(id: .init(rawValue: id), isCurrent: context.isCurrent)
                }
            )
        }
        .background(Self.palette.background.ignoresSafeArea())
        .overlay {
            if isMapPresented {
                WorkspaceMapView(
                    workspaceName: "cmux",
                    snapshot: snapshot,
                    openTab: { id in
                        withAnimation(.snappy(duration: 0.3)) { isMapPresented = false }
                        selectedTabID = id
                    },
                    fetchPreview: { id in Self.fakeFrame(for: id) },
                    dismiss: {
                        withAnimation(.snappy(duration: 0.3)) { isMapPresented = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 1.06)))
                .zIndex(2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileSurfaceNavigatorPreview")
    }

    @ViewBuilder
    private func fakePage(id: MobileTerminalPreview.ID, isCurrent: Bool) -> some View {
        let tab = layout.orderedTabs.first { $0.id == id }
        if tab?.kind == .browser {
            SurfacePlaceholderPage(title: tab?.title ?? "", kind: .browser, palette: Self.palette)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.fakeLines(for: id), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Self.palette.foreground.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer()
                Text(verbatim: isCurrent ? "▌" : "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Self.palette.foreground)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Self.palette.background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("MobileSurfaceFakePage-\(id.rawValue)")
        }
    }

    private static func fakeLines(for id: MobileTerminalPreview.ID) -> [String] {
        switch id {
        case "tab-agent":
            return [
                "$ claude",
                "> implement the pane map",
                "⏺ Reading WorkspaceMapView.swift…",
                "⏺ Wrote 3 files, 212 insertions",
                "  Running swift test… ✓ 9 passed",
            ]
        case "tab-shell":
            return [
                "$ git status --short",
                " M Sources/App.swift",
                "?? docs/plan.md",
                "$",
            ]
        case "tab-server":
            return [
                "$ bun dev",
                "  ▲ Next.js 15.3",
                "  - Local: http://localhost:3777",
                "✓ Ready in 1.2s",
                "? Port 3777 busy, retry? (y/n)",
            ]
        default:
            return ["$"]
        }
    }

    /// A synthesized styled frame so the map's miniatures render without a Mac.
    private static func fakeFrame(for id: MobileTerminalPreview.ID) -> MobileTerminalRenderGridFrame? {
        let lines = fakeLines(for: id)
        let spans = lines.enumerated().map { row, text in
            MobileTerminalRenderGridFrame.RowSpan(row: row, column: 0, styleID: 0, text: text)
        }
        return try? MobileTerminalRenderGridFrame(
            surfaceID: id.rawValue,
            stateSeq: 1,
            columns: 60,
            rows: 18,
            rowSpans: spans,
            terminalForeground: "#f8f8f2",
            terminalBackground: "#272822"
        )
    }
}
#endif
