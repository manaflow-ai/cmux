public import AppKit

/// The window's widget area as a sidebar section (``AppSectionProvider/widgets``): a section the
/// layout document does not hold, shown in the band below the list while the person has a widget
/// placed or edits them, drawn through the same AppKit scene path as app sections.
@MainActor
public final class AppWidgetSection {
    /// The section's contribution id (never in the layout document).
    public static let contribution = "cmux/widgets#sidebar"

    public let area: AppWidgetArea
    private var view: AppWidgetAreaView?
    /// Runs when the section's height may have changed or it comes or goes.
    var onContentChange: (() -> Void)?

    init(client: AppsClient, place: String) {
        area = AppWidgetArea(client: client, place: place)
        area.onChange = { [weak self] in
            self?.view?.sync()
            self?.onContentChange?()
        }
        // Reads the layout only (the daemon's catalog and mirror): no widget mounts until one is placed.
        area.start()
    }

    /// Whether the sidebar shows the section: a widget is placed, or the person edits them.
    public var isShown: Bool { area.hasTiles || area.isEditing }
    public var title: String { area.title }

    func makeView() -> AppWidgetAreaView {
        if let view { return view }
        let made = AppWidgetAreaView(area: area)
        made.onContentSizeChange = { [weak self] in self?.onContentChange?() }
        view = made
        return made
    }

    func preferredHeight(width: CGFloat) -> CGFloat { view?.preferredHeight(width: width) ?? 0 }

    /// `menu` with Edit Widgets and Add Widget at its end (the section header's menu, the sidebar's
    /// background menu), when the person has a widget to place or placed; else `menu` as it is.
    public func appendingMenuItems(to menu: NSMenu?) -> NSMenu? {
        guard area.hasTiles || !area.catalog.widgets.isEmpty else { return menu }
        let menu = menu ?? NSMenu()
        if menu.items.contains(where: { !$0.isSeparatorItem }) { menu.addItem(.separator()) }
        for item in makeView().areaMenuItems() { menu.addItem(item) }
        return menu
    }

    func releaseAll() { area.releaseAll() }
}
