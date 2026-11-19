import AppKit
import CmuxNextDesign

/// The Add Widget gallery, as Apple's widget gallery: a popover listing every widget the person can
/// place in the place, each with a live preview per size it takes there (mounted with `preview:
/// true`: sample data, writes nothing). A click on a preview adds that widget at that size; the
/// previews unmount when the gallery closes. It reads the list when it opens and follows its
/// changes while open, so a widget just installed comes into it.
@MainActor
final class AppWidgetGallery {
    let area: AppWidgetArea
    private let content = AppWidgetGalleryView()
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.widgets.gallery"))
    private let card: OverlaySurfaceView
    private var previews: [AppMount] = []
    /// The widgets the shown rows preview, in order.
    private var shownApps: [String] = []

    init(area: AppWidgetArea) {
        self.area = area
        card = Glass.makeMenuPanel(content: content)
        popup.panel.adoptPopupStyle(card: card)
        popup.onDismiss = { [weak self] in self?.endPreviews() }
        content.onAdd = { [weak self] app, size in
            self?.area.edit(.add(app: app, size: size, before: nil))
            self?.close()
        }
    }

    var isShown: Bool { popup.isShown }

    /// Opens beside `anchor` (the widget area) with previews of every placeable widget.
    func show(relativeTo anchor: NSView) {
        guard let window = anchor.window else { return }
        endPreviews()
        var rows: [AppWidgetGalleryView.Row] = []
        for spec in area.catalog.widgets {
            let tiles = spec.sidebarSizes.compactMap { size -> AppWidgetGalleryView.Preview? in
                guard let mount = area.preview(spec.app, size: size) else { return nil }
                previews.append(mount)
                return AppWidgetGalleryView.Preview(size: size, mount: mount)
            }
            if !tiles.isEmpty { rows.append(AppWidgetGalleryView.Row(spec: spec, previews: tiles)) }
        }
        content.show(rows)
        shownApps = area.catalog.widgets.map(\.app)
        popup.panel.adoptThemeScope(of: anchor)
        card.applyTheme()
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        let size = CGSize(width: AppWidgetGalleryView.width, height: content.preferredHeight)
        guard popup.show(size: size, anchor: rect, in: window, preferred: .below, sideBySide: true) != nil else {
            return endPreviews()
        }
        // The list may have changed since the area last read it (a widget just installed): the
        // read's answer comes back through ``follow(relativeTo:)``.
        area.read()
    }

    /// Shows the rows again when the list of widgets changed while the gallery is open.
    func follow(relativeTo anchor: NSView) {
        guard isShown, area.catalog.widgets.map(\.app) != shownApps else { return }
        show(relativeTo: anchor)
    }

    func close() {
        popup.hide()
        endPreviews()
    }

    private func endPreviews() {
        for mount in previews { area.endPreview(mount) }
        previews.removeAll()
        content.show([])
    }
}
