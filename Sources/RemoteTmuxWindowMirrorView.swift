import Bonsplit
import SwiftUI

/// Renders a mirrored tmux window's multi-pane layout as nested splits inside a
/// single cmux tab. Each pane is a real ``TerminalPanel`` (rendered via
/// ``TerminalPanelView`` for native chrome) topped with a small control header
/// (split / close) that doubles as a clearly visible separator between panes.
@MainActor
struct RemoteTmuxWindowMirrorView: View {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int

    var body: some View {
        GeometryReader { geo in
            RemoteTmuxLayoutContainer(
                node: mirror.layout,
                mirror: mirror,
                appearance: appearance,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority
            )
            .frame(width: geo.size.width, height: geo.size.height)
            // Size the remote tmux window to the rendered area so pane content
            // matches the on-screen grid.
            .onAppear { mirror.updateClientSize(contentSizePoints: geo.size) }
            .onChange(of: geo.size) { _, newSize in
                mirror.updateClientSize(contentSizePoints: newSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the terminal background so the area never shows through as black.
        .background(Color(nsColor: appearance.backgroundColor))
    }
}

/// Recursive split container that lays out one ``RemoteTmuxLayoutNode`` subtree,
/// sizing children in proportion to their tmux cell extents. The gaps between
/// children show the divider color so both horizontal and vertical separators
/// are visible.
@MainActor
private struct RemoteTmuxLayoutContainer: View {
    let node: RemoteTmuxLayoutNode
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int

    private let dividerThickness: CGFloat = 2

    var body: some View {
        switch node.content {
        case let .pane(paneId):
            leaf(paneId: paneId)
        case let .horizontal(children):
            splitStack(children: children, axis: .horizontal)
        case let .vertical(children):
            splitStack(children: children, axis: .vertical)
        }
    }

    @ViewBuilder
    private func leaf(paneId: Int) -> some View {
        if let panel = mirror.panel(forPane: paneId) {
            VStack(spacing: 0) {
                RemoteTmuxPaneHeader(
                    isActive: mirror.activePaneId == paneId,
                    appearance: appearance,
                    onFocus: { mirror.focus(pane: paneId) },
                    onSplitRight: { mirror.requestSplit(fromPane: paneId, vertical: false) },
                    onSplitDown: { mirror.requestSplit(fromPane: paneId, vertical: true) },
                    onClose: { mirror.requestKillPane(paneId) }
                )
                TerminalPanelView(
                    panel: panel,
                    paneId: mirror.syntheticPaneID(forPane: paneId),
                    isFocused: mirror.activePaneId == paneId,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: true,
                    appearance: appearance,
                    hasUnreadNotification: false,
                    terminalAgentContext: "",
                    onFocus: { mirror.focus(pane: paneId) },
                    onResumeAgentHibernation: {},
                    onAutoResumeAgentHibernation: {},
                    onTriggerFlash: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(paneId)
            .background(Color(nsColor: appearance.backgroundColor))
        } else {
            Color(nsColor: appearance.backgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func splitStack(children: [RemoteTmuxLayoutNode], axis: Axis) -> some View {
        let weights = children.map { CGFloat(axis == .horizontal ? $0.width : $0.height) }
        let total = max(1, weights.reduce(0, +))
        GeometryReader { geo in
            let span = axis == .horizontal ? geo.size.width : geo.size.height
            let usable = max(1, span - dividerThickness * CGFloat(max(0, children.count - 1)))
            if axis == .horizontal {
                HStack(spacing: dividerThickness) {
                    childViews(children, weights: weights, total: total, usable: usable, axis: axis)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                VStack(spacing: dividerThickness) {
                    childViews(children, weights: weights, total: total, usable: usable, axis: axis)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        // The inter-child gaps reveal this as the split divider.
        .background(appearance.dividerColor)
    }

    @ViewBuilder
    private func childViews(
        _ children: [RemoteTmuxLayoutNode],
        weights: [CGFloat],
        total: CGFloat,
        usable: CGFloat,
        axis: Axis
    ) -> some View {
        ForEach(children.indices, id: \.self) { index in
            let dimension = usable * weights[index] / total
            RemoteTmuxLayoutContainer(
                node: children[index],
                mirror: mirror,
                appearance: appearance,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority
            )
            .frame(
                width: axis == .horizontal ? dimension : nil,
                height: axis == .vertical ? dimension : nil
            )
        }
    }
}

/// A compact per-pane control bar shown above each mirrored tmux pane: a focus
/// indicator plus split-right / split-down / close buttons (which drive tmux
/// `split-window` / `kill-pane`). Gives mirrored panes native-feeling chrome and
/// a clearly visible separator.
@MainActor
private struct RemoteTmuxPaneHeader: View {
    let isActive: Bool
    let appearance: PanelAppearance
    let onFocus: () -> Void
    let onSplitRight: () -> Void
    let onSplitDown: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            Spacer(minLength: 0)
            button(
                system: "square.split.2x1",
                label: String(localized: "remoteTmux.pane.splitRight", defaultValue: "Split Right"),
                action: onSplitRight
            )
            button(
                system: "square.split.1x2",
                label: String(localized: "remoteTmux.pane.splitDown", defaultValue: "Split Down"),
                action: onSplitDown
            )
            button(
                system: "xmark",
                label: String(localized: "remoteTmux.pane.close", defaultValue: "Close Pane"),
                action: onClose
            )
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(appearance.dividerColor).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
    }

    private func button(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
