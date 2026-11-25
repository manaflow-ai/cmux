public import AppKit
import CmuxNextDesign
public import CmuxNextPages

/// The native App Store (Debug Settings `apps.store.surface = native`): a top bar with the five tabs
/// (Today, Discover, Categories, Updates, Installed) and the search field, and under it one scrolling
/// column with the tab or a listing. AppKit, built from the design tokens; every list and listing is the
/// Rust owner's (``AppStoreOps``). The React page stays the default until this one reaches parity.
public final class AppStoreNativeView: NSView, NSTextFieldDelegate {
    let model: AppStoreModel
    private let tabBar = AppStoreLayout.stack([], vertical: false, spacing: Metrics.space1)
    private let searchField = ThemedTextField()
    private lazy var searchBox = ThemedFieldBox(field: searchField, height: AppStoreButton.height)
    private let scroll = OverlayScrollView()
    private let document = AppStoreFlippedView()
    private var content: NSView?
    private var builtWidth: CGFloat = 0
    private var rebuildQueued = false

    /// - Parameter ops: The owner's reads and the person's changes.
    public init(ops: any AppStoreOps) {
        model = AppStoreModel(ops: ops)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.appStore.native")
        build()
        model.onChange = { [weak self] in self?.queueRebuild() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The native store over this Mac's supervisor, reading at once and opened on `route`
    /// (``AppStoreTab/route(appID:tab:)``): reads through `client`; install, update and remove through `changes`,
    /// the App Store's provider with its consent card (the one the React page and `app.install` share); Hide/Show as
    /// the person's `apps-set`; `open` runs `app.open`, `openLink` opens a listing's link in cmux's browser.
    public convenience init(client: AppsClient, changes: ConfirmingPageProvider, route: String?,
                            open: @escaping @MainActor (String) -> Void, openLink: @escaping @MainActor (URL) -> Void) {
        self.init(ops: AppStoreClientOps(client: client, changes: changes, open: open, openLink: openLink))
        changes.anchor = { [weak self] in self }
        model.start()
        if let route { show(route: route) }
    }

    /// Starts reading the store (once, when the page first shows).
    public func start() { model.start() }

    /// Shows a route's listing, else its tab (`appStore.show --app/--tab`).
    public func show(route: String) {
        let parsed = AppStoreTab.parse(route: route)
        show(appID: parsed.appID, tab: parsed.tab)
    }

    /// Shows `appID`'s listing, else `tab` (`appStore.show --app/--tab`); nil for both keeps what shows.
    public func show(appID: String?, tab: AppStoreTab?) {
        if let tab { model.show(tab: AppStoreTab.Native(tab)) }
        if let appID { model.select(appID) }
    }

    public override var isFlipped: Bool { true }

    private func build() {
        let bar = AppStoreSurfaceView()
        searchField.placeholderString = AppStoreStrings.search
        searchField.font = Typography.body
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("cmux.appStore.search")
        searchBox.translatesAutoresizingMaskIntoConstraints = false
        let separator = AppStoreSurfaceView()
        separator.fill = { Palette.separator }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        for view in [bar, separator, scroll] as [NSView] { addSubview(view) }
        bar.addSubview(tabBar)
        bar.addSubview(searchBox)
        let margin = Metrics.space4
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: margin),
            tabBar.topAnchor.constraint(equalTo: bar.topAnchor, constant: Metrics.space2),
            tabBar.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -Metrics.space2),
            searchBox.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -margin),
            searchBox.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            searchBox.widthAnchor.constraint(equalToConstant: 240),
            searchBox.leadingAnchor.constraint(greaterThanOrEqualTo: tabBar.trailingAnchor, constant: margin),
            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        SystemScrollers.follow(scroll)
        buildTabs()
    }

    private func buildTabs() {
        // visible-only: the tab bar is the six fixed AppStoreTab.Native tabs, never a list of rows.
        for view in tabBar.arrangedSubviews { view.removeFromSuperview() }
        for tab in AppStoreTab.Native.allCases {
            let selected = model.tab == tab && model.listing == nil
            let button = AppStoreButton(tab.title, style: selected ? .secondary : .plain,
                                        identifier: "cmux.appStore.tab.\(tab.rawValue)") { [weak self] in
                self?.searchField.stringValue = ""
                self?.model.search("")
                self?.model.show(tab: tab)
            }
            button.setAccessibilityValue(selected)
            tabBar.addArrangedSubview(button)
        }
    }

    public func controlTextDidChange(_ notification: Notification) {
        model.search(searchField.stringValue)
    }

    public override func layout() {
        // A queued change or a new width builds the column before this pass lays it out.
        if rebuildQueued || abs(scroll.contentView.bounds.width - builtWidth) > 0.5 {
            rebuildQueued = false
            rebuild()
        }
        super.layout()
    }

    /// Model changes in one turn (icons landing one by one) draw once, in the next layout pass.
    private func queueRebuild() {
        rebuildQueued = true
        needsLayout = true
    }

    private func rebuild() {
        buildTabs()
        let width = scroll.contentView.bounds.width
        builtWidth = width
        guard width > 0 else { return }
        let margin = Metrics.space4
        let inner = max(width - 2 * margin, 200)
        let next = AppStoreContentBuilder(model: model, width: inner).build()
        content?.removeFromSuperview()
        document.addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: document.topAnchor, constant: margin),
            next.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: margin),
            next.widthAnchor.constraint(equalToConstant: inner),
            document.bottomAnchor.constraint(equalTo: next.bottomAnchor, constant: margin),
        ])
        content = next
    }
}

/// The scroll view's document: top-down, so the column starts at the top.
final class AppStoreFlippedView: NSView {
    override var isFlipped: Bool { true }
}
