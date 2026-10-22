import AppKit
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign

/// One download in the Downloads popup: its icon, name (truncated in the middle; the tooltip shows
/// it whole) and status, and Show in Finder on the hovered row (Chrome's folder button; its slot
/// is always there, so the name does not shift). Pointer handling is ``BrowserDownloadRowEventView``:
/// a click opens the finished file, a drag carries it out, a right-click shows its menu. The row
/// follows its own download's name and status.
final class BrowserDownloadPopupRow: BrowserDownloadsHoverFill {
    let download: BrowserDownload
    private let model: BrowserDownloadsPopupModel
    private let colors: BrowserDownloadsPopupColors
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let reveal = NSButton()
    private let events = BrowserDownloadRowEventView()
    private var observation: Task<Void, Never>?

    init(download: BrowserDownload, model: BrowserDownloadsPopupModel, colors: BrowserDownloadsPopupColors) {
        self.download = download
        self.model = model
        self.colors = colors
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fill = colors.hover
        setAccessibilityIdentifier("browser.downloads.row")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        onHover = { [weak self] inside in
            if inside { self?.model.pointerEntered() }
            self?.refreshReveal()
        }

        name.font = Typography.body
        name.textColor = colors.primary
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = Typography.caption
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [name, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        icon.setAccessibilityElement(false)

        reveal.isBordered = false
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: BrowserHitStrings.downloadShowInFinder)?
            .withSymbolConfiguration(.init(pointSize: TypeScale.body, weight: .regular))
        reveal.contentTintColor = colors.secondary
        reveal.target = self
        reveal.action = #selector(revealClicked)
        reveal.themedToolTip = BrowserHitStrings.downloadShowInFinder
        reveal.setAccessibilityLabel(BrowserHitStrings.downloadShowInFinder)
        reveal.setAccessibilityIdentifier("browser.downloads.reveal")

        events.fileProvider = { [download] in BrowserDownloadsMenu.draggableFile(download) }
        events.menuProvider = { [weak model, download] in model?.menu(for: download) }
        events.onOpen = { [weak model] file in model?.onOpen(file) }
        events.onHover = { [weak self] inside in
            if inside { self?.model.pointerEntered() }
        }

        let content = NSStackView(views: [icon, text])
        content.orientation = .horizontal
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        events.translatesAutoresizingMaskIntoConstraints = false
        reveal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(events)
        addSubview(reveal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: reveal.leadingAnchor, constant: -6),
            events.leadingAnchor.constraint(equalTo: leadingAnchor),
            events.topAnchor.constraint(equalTo: topAnchor),
            events.bottomAnchor.constraint(equalTo: bottomAnchor),
            events.trailingAnchor.constraint(equalTo: reveal.leadingAnchor, constant: -6),
            reveal.widthAnchor.constraint(equalToConstant: 24),
            reveal.heightAnchor.constraint(equalToConstant: 24),
            reveal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            reveal.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
        observation = Task { [weak self, download] in
            for await _ in ObservationStream({ (download.filename, BrowserDownloadsMenu.status(download)) }) {
                self?.refresh()
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

    private var failed: Bool {
        if case .failed = download.status { return true }
        return false
    }

    private func refresh() {
        icon.image = BrowserDownloadsMenu.icon(for: download, size: 24)
        name.stringValue = download.filename
        let text = BrowserDownloadsMenu.status(download)
        status.stringValue = text
        status.textColor = failed ? colors.danger : colors.secondary
        themedToolTip = download.filename
        setAccessibilityLabel("\(download.filename), \(text)")
        refreshReveal()
    }

    private func refreshReveal() {
        reveal.isHidden = !(isHovered && BrowserDownloadsMenu.draggableFile(download) != nil)
    }

    @objc private func revealClicked() {
        guard let file = BrowserDownloadsMenu.draggableFile(download) else { return }
        model.onReveal(file)
    }
}
