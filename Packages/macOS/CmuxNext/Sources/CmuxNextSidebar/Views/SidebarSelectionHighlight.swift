import AppKit

/// The one selection highlight of a sidebar (SIDEBAR-SELECTION-ONE-MODEL):
/// one pill under every item view, drawn once in the sidebar's coordinates
/// and moved with the same spring between any two items, whether a
/// top-section item (Home, the App Store) or a workspace or group row. It
/// follows `SidebarModel.selectedItem`. The list reports where its selected
/// row is (its decoration pill no longer draws); top items give their own
/// frames. Tile arrangements keep their own raised fill (a pill under a tile
/// card would be hidden).
@MainActor
final class SidebarSelectionHighlight {
    let view = SidebarDecorationView(frame: .zero)
    private weak var sidebar: SidebarView?
    /// The selected row in list coordinates, as the list last reported it.
    private var listPill: CGRect?
    private var observers: [any NSObjectProtocol] = []

    /// Puts the pill under every view of `sidebar` and follows its scroll views.
    func install(in sidebar: SidebarView) {
        self.sidebar = sidebar
        view.autoresizingMask = [.width, .height]
        sidebar.addSubview(view, positioned: .below, relativeTo: nil)
        sidebar.list.decorations.onPill = { [weak self] frame, animated in
            self?.listPill = frame
            self?.refresh(animated: animated)
        }
        for scroll in [sidebar.scrollView, sidebar.aboveScroll, sidebar.belowScroll] {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                                    queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(animated: false) } // crash-allow: posted on the main thread by AppKit
            })
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Moves the pill to the selected item (springs when `animated`).
    func refresh(animated: Bool) {
        guard let sidebar else { return }
        view.frame = sidebar.bounds
        view.setPill(frame(in: sidebar), animated: animated)
    }

    /// The selected item's pill in the highlight view's coordinates, clipped
    /// to the scroll view that shows it; nil when it shows nowhere.
    private func frame(in sidebar: SidebarView) -> CGRect? {
        switch sidebar.model.selectedItem {
        case .topItem(let id)?:
            for region in [sidebar.aboveRegion, sidebar.belowRegion] {
                guard let item = region.itemView(id), !item.isHiddenOrHasHiddenAncestor,
                      !item.drawsOwnSelection else { continue }
                return clip(item.convert(item.selectionRect, to: view), to: region.enclosingScrollView)
            }
            return nil
        case .workspace?, .group?:
            guard let listPill else { return nil }
            return clip(sidebar.list.convert(listPill, to: view), to: sidebar.scrollView)
        case nil:
            return nil
        }
    }

    private func clip(_ rect: CGRect, to scroll: NSScrollView?) -> CGRect? {
        guard let scroll else { return rect }
        let visible = scroll.convert(scroll.bounds, to: view).intersection(rect)
        return visible.isNull || visible.isEmpty ? nil : visible
    }
}
