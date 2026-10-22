import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign

/// The Downloads popup's content, in AppKit (plans/cmux-next/no-swiftui-DESIGN.md): the downloads
/// newest first (at most ``BrowserDownloadsPopup/shown``, scrolling past six), then one full-width
/// row per footer command, as Chrome's bubble footer. Rows hold a download and the model's
/// callbacks only; ``reload()`` rebuilds them when the shown downloads or Clear change, and each
/// row follows its own download's status. A click acts on the first click, also while the popup
/// opened without the keys.
final class BrowserDownloadsPopupView: NSView {
    private let model: BrowserDownloadsPopupModel
    private static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 44
    private static let visibleRows = 6

    private let stack = NSStackView()
    private let empty = NSTextField(labelWithString: BrowserHitStrings.downloadsEmpty)
    private lazy var emptyBox = Self.padded(empty, vertical: 24)
    private let rowList = NSStackView()
    private let scroll = NSScrollView()
    private lazy var scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
    private let separator = NSView()
    private let footer = NSStackView()
    private lazy var showFolder = BrowserDownloadsFooterRow(symbol: "folder", title: BrowserHitStrings.downloadsShowFolder,
                                                            identifier: "browser.downloads.showFolder") { [weak self] in
        self?.model.onShowFolder()
    }
    private lazy var clear = BrowserDownloadsFooterRow(symbol: "xmark.circle", title: BrowserHitStrings.downloadsClear,
                                                       identifier: "browser.downloads.clear") { [weak self] in
        self?.model.clear()
        self?.reload()
    }
    private var shown: (ids: [UUID], shows: Int, colors: BrowserDownloadsPopupColors)?
    private var tracking: NSTrackingArea?
    private var observation: Task<Void, Never>?

    init(model: BrowserDownloadsPopupModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        setAccessibilityIdentifier("browser.downloads.popup")
        setAccessibilityElement(false)
        build()
        observation = Task { [weak self, model] in
            for await _ in ObservationStream({ (model.rows.map(\.id), model.canClear, model.shows) }) {
                self?.reload()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    nonisolated override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { model.pointerEntered() }

    private static func padded(_ view: NSView, vertical: CGFloat) -> NSStackView {
        let box = NSStackView(views: [view])
        box.orientation = .vertical
        box.alignment = .centerX
        box.edgeInsets = NSEdgeInsets(top: vertical, left: 0, bottom: vertical, right: 0)
        return box
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        empty.font = Typography.body
        empty.setAccessibilityIdentifier("browser.downloads.empty")

        rowList.orientation = .vertical
        rowList.spacing = 0
        rowList.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        rowList.translatesAutoresizingMaskIntoConstraints = false
        let clip = BrowserDownloadsClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = rowList
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false

        footer.orientation = .vertical
        footer.spacing = 0
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        footer.addArrangedSubview(showFolder)
        footer.addArrangedSubview(clear)

        for view in [emptyBox, scroll, separator, footer] as [NSView] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for view in [showFolder, clear] { view.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            scrollHeight,
            separator.heightAnchor.constraint(equalToConstant: 1),
            rowList.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rowList.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            rowList.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Brings the content to the model: rows rebuild when the shown downloads, the show or the
    /// colors change (a new show starts every row without its last hover); Clear follows `canClear`.
    func reload() {
        let colors = model.colors
        let rows = model.rows
        let ids = rows.map(\.id)
        empty.textColor = colors.secondary
        separator.layer?.backgroundColor = colors.separator.cgColor
        showFolder.apply(colors)
        clear.apply(colors)
        clear.isHidden = !model.canClear
        emptyBox.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        if shown?.ids != ids || shown?.shows != model.shows || shown?.colors != colors {
            shown = (ids, model.shows, colors)
            for view in rowList.arrangedSubviews { view.removeFromSuperview() }
            for download in rows {
                let row = BrowserDownloadPopupRow(download: download, model: model, colors: colors)
                rowList.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowList.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            }
            scrollHeight.constant = CGFloat(min(rows.count, Self.visibleRows)) * Self.rowHeight + 8
        }
    }
}

/// A clip view with a top-left origin, so the newest download sits at the top.
private final class BrowserDownloadsClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}
