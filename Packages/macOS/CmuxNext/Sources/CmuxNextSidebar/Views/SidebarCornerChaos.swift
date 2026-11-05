import AppKit
import CmuxNextDesign
import CmuxNextCompat

/// Sidebar Thunderdome E: places the window's corner treatment (`CornerChaosView`, Debug Settings
/// `chrome.cornerChaos`, off by default) from the main pane card and the sidebar's selected row.
/// The sidebar mounts its view in its own superview, just above itself (as it mounts its resize
/// handle), and reads the card from the window's chrome shade (`MainPaneChromeShadeView`), which
/// the window root keeps on the card every layout pass and every frame of a sidebar slide. This
/// follows the choice, the density (ultra-compact keeps the shipped corner), the selection and the
/// list's scroll. It reads the sidebar only; nothing here lays out or repaints the list.
@MainActor
final class SidebarCornerChaos {
    let view = CornerChaosView(frame: .zero)
    private weak var sidebar: SidebarContainerView?
    private weak var shade: MainPaneChromeShadeView?
    private var choice: Task<Void, Never>?
    private var selection: Task<Void, Never>?

    init(sidebar: SidebarContainerView) {
        self.sidebar = sidebar
        choice = Task { [weak self] in
            for await style in ObservationStream({ () -> CornerChaosStyle in
                DesignSettings.shared.densityTokens.id == DensityPreset.ultraCompact.rawValue ? .off : CornerChaosStyle.tunable.value
            }) {
                guard let self else { return }
                apply(style)
            }
        }
    }

    /// Puts the view over `sidebar` in its superview, following the card of `shade`.
    func mount(over sidebar: NSView, in superview: NSView, shade: MainPaneChromeShadeView) {
        self.shade = shade
        superview.addSubview(view, positioned: .above, relativeTo: sidebar)
        view.frame = superview.bounds
        view.autoresizingMask = [.width, .height]
        shade.onCardChange = { [weak self] in self?.update(animated: false) }
        update(animated: false)
    }

    private func apply(_ style: CornerChaosStyle) {
        view.style = style
        selection?.cancel()
        selection = nil
        sidebar?.sidebarView.onListScroll = nil
        guard style != .off, let model = sidebar?.model else { return }
        // The list patches its rows in the selection's turn, so the marks follow on the next.
        selection = Task { [weak self] in
            for await _ in ObservationStream({ () -> String in
                let id = model.activeWorkspaceID
                let workspace = id.flatMap(model.workspace)
                return "\(String(describing: id))|\(workspace?.title ?? "")|\(workspace?.color?.rawValue ?? "")"
            }) {
                await Task.yield()
                guard let self else { return }
                update(animated: true)
            }
        }
        sidebar?.sidebarView.onListScroll = { [weak self] in self?.update(animated: false) }
        update(animated: false)
    }

    /// Reads the card and the selected row and places the marks: the card moved, a scroll, a
    /// selection change (`animated`: the marks spring to the new row).
    func update(animated: Bool) {
        guard view.style != .off, let sidebar, let shade, !sidebar.isHidden, sidebar.frame.width >= 1,
              !shade.cardRect.isEmpty else {
            view.update(nil, animated: false)
            return
        }
        let card = view.convert(shade.cardRect, from: shade)
        let row = sidebar.selectedRowFrameInWindow.map { view.convert($0, from: nil) }
        let look = sidebar.selectedWorkspaceLook
        view.update(CornerChaosView.Geometry(card: card, cardRadius: shade.cardRadius, row: row, rowRadius: SidebarStyle.rowCornerRadius,
                                             title: look?.title, color: look?.color), animated: animated)
    }
}

extension SidebarContainerView {
    /// Mounts the corner treatment beside this view (`viewDidMoveToSuperview`), over it and under
    /// what the window adds later (the titlebar controls).
    func mountCornerChaos() {
        guard let superview, let shade = superview.subviews.lazy.compactMap({ $0 as? MainPaneChromeShadeView }).first else {
            cornerChaos?.view.removeFromSuperview()
            return
        }
        let chaos = cornerChaos ?? SidebarCornerChaos(sidebar: self)
        cornerChaos = chaos
        chaos.mount(over: self, in: superview, shade: shade)
    }

    /// The selected row's frame in window coordinates as drawn now, or nil when no row is selected,
    /// it is not realized, or it is scrolled out of the list's viewport.
    var selectedRowFrameInWindow: CGRect? {
        let list = sidebarView.list
        guard let key = list.selectedRowKey, let row = list.rowViews[key], !row.isHidden, row.window != nil else { return nil }
        let rect = row.convert(row.bounds, to: nil)
        if let clip = list.enclosingScrollView?.contentView {
            let visible = clip.convert(clip.bounds, to: nil)
            guard visible.intersects(rect) else { return nil }
        }
        return rect
    }

    /// The selected workspace's name and color (nil when the selection is no workspace).
    var selectedWorkspaceLook: (title: String, color: GroupColor?)? {
        guard let id = model.activeWorkspaceID, let workspace = model.workspace(id) else { return nil }
        return (workspace.title, workspace.color)
    }
}
