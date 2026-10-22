import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The vault: a search field over the session list. AppKit (plans/cmux-next/no-swiftui-DESIGN.md).
/// Rows get value snapshots and an action bundle only (the snapshot boundary rule) and rebuild
/// only when the shown rows, the selection or the colors change.
final class VaultListView: NSView, NSTextFieldDelegate {
    private let vault: SessionVault
    private let actions: VaultRowActions
    private let search = ThemedTextField()
    private let refresh = NSButton()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var shown: (rows: [VaultRow], selection: String?, colors: VaultColors)?
    var colors = VaultColors() { didSet { if colors != oldValue { reload() } } }
    private var observation: Task<Void, Never>?

    init(vault: SessionVault, actions: VaultRowActions) {
        self.vault = vault
        self.actions = actions
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        build()
        reload()
        observation = Task { [weak self, vault] in
            for await _ in ObservationStream({ (vault.shownRows, vault.selection, vault.isLoading, vault.rows.isEmpty) }) {
                self?.reload()
            }
        }
        // task-owner: the first load of the vault's sessions; ends when it is read
        Task { [vault] in await vault.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    nonisolated override var isFlipped: Bool { true }

    private func build() {
        search.placeholderString = VaultStrings.searchPlaceholder
        search.font = Typography.body
        search.delegate = self
        search.setAccessibilityLabel(VaultStrings.searchPlaceholder)
        search.setAccessibilityIdentifier("cmux.vault.search")
        let searchBox = ThemedFieldBox(field: search, height: Metrics.controlHeight)
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: VaultStrings.refresh)
        refresh.isBordered = false
        refresh.target = self
        refresh.action = #selector(refreshClicked)
        refresh.setAccessibilityLabel(VaultStrings.refresh)
        refresh.setAccessibilityIdentifier("cmux.vault.refresh")
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        let bar = NSStackView(views: [searchBox, refresh])
        bar.orientation = .horizontal
        bar.spacing = Metrics.panelInset
        bar.edgeInsets = NSEdgeInsets(top: Metrics.panelInset, left: Metrics.panelInset, bottom: Metrics.panelInset, right: Metrics.panelInset)
        bar.translatesAutoresizingMaskIntoConstraints = false

        empty.font = Typography.caption
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.setAccessibilityIdentifier("cmux.vault.empty")

        list.orientation = .vertical
        list.spacing = 1
        list.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.panelInset / 2, bottom: 0, right: Metrics.panelInset / 2)
        list.translatesAutoresizingMaskIntoConstraints = false
        let clip = VaultClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        for view in [bar, empty, scroll] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            list.topAnchor.constraint(equalTo: clip.topAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.panelInset * 2),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.panelInset * 2),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    /// Brings the list to the vault now.
    func reload() {
        layer?.backgroundColor = colors.background.cgColor
        refresh.isEnabled = !vault.isLoading
        if search.currentEditor() == nil, search.stringValue != vault.filter { search.stringValue = vault.filter }
        let rows = vault.shownRows
        empty.stringValue = vault.rows.isEmpty ? VaultStrings.empty : VaultStrings.noMatch
        empty.textColor = colors.tertiary
        empty.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        guard shown?.rows != rows || shown?.selection != vault.selection || shown?.colors != colors else {
            for case let row as VaultRowView in list.arrangedSubviews { row.refreshAgo() }
            return
        }
        shown = (rows, vault.selection, colors)
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        for row in rows {
            let view = VaultRowView(row: row, isSelected: row.id == vault.selection, colors: colors, actions: actions)
            list.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -Metrics.panelInset).isActive = true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        vault.filter = search.stringValue
        reload()
    }

    @objc private func refreshClicked() {
        // task-owner: one reload of the vault's sessions; ends when it is read
        Task { [vault] in await vault.reload() }
    }
}

/// A clip view with a top-left origin, so the newest session sits at the top.
private final class VaultClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}
