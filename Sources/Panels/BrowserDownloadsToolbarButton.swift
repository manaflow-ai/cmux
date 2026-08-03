import AppKit

@MainActor
final class BrowserDownloadsToolbarButtonView: NSView, NSPopoverDelegate {
    private let button = NSButton()
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var trackingAreaToken: NSTrackingArea?

    private var downloads: [BrowserDownloadRecord] = []
    private var seenIDs: Set<String> = []
    private var onOpen: ((BrowserDownloadRecord) -> Void)?
    private var onReveal: ((BrowserDownloadRecord) -> Void)?
    private var onClear: (() -> Void)?
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8

        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = String(localized: "browser.downloads.title", defaultValue: "Downloads")
        button.setAccessibilityLabel(button.toolTip)
        addSubview(button)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(iconView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(spinner)

        badgeLabel.alignment = .center
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeLabel.layer?.cornerRadius = 7
        badgeLabel.layer?.borderWidth = 1.5
        badgeLabel.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badgeLabel)

        widthConstraint = widthAnchor.constraint(equalToConstant: 28)
        heightConstraint = heightAnchor.constraint(equalToConstant: 28)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,
            spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            badgeLabel.centerXAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            badgeLabel.centerYAnchor.constraint(equalTo: button.topAnchor, constant: 3),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            badgeLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaToken = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func update(
        downloads: [BrowserDownloadRecord],
        isDownloading: Bool,
        iconPointSize: CGFloat,
        hitSize: CGFloat,
        onOpen: @escaping (BrowserDownloadRecord) -> Void,
        onReveal: @escaping (BrowserDownloadRecord) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.downloads = downloads
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onClear = onClear
        widthConstraint.constant = hitSize
        heightConstraint.constant = hitSize
        iconWidthConstraint.constant = iconPointSize
        iconHeightConstraint.constant = iconPointSize

        if isDownloading {
            iconView.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            iconView.isHidden = false
            let configuration = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)
            iconView.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: button.toolTip
            )?.withSymbolConfiguration(configuration)
        }

        let unseenCount = downloads.reduce(0) { $0 + (seenIDs.contains($1.id) ? 0 : 1) }
        badgeLabel.stringValue = unseenCount > 99 ? "99+" : "\(unseenCount)"
        badgeLabel.isHidden = unseenCount == 0
        if popover?.isShown == true {
            updatePopoverContent()
        }
    }

    @objc private func togglePopover(_ sender: NSButton) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        seenIDs.formUnion(downloads.map(\.id))
        badgeLabel.isHidden = true
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        self.popover = popover
        updatePopoverContent()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    func teardown() {
        popover?.close()
        popover = nil
        onOpen = nil
        onReveal = nil
        onClear = nil
    }

    private func updatePopoverContent() {
        guard let popover else { return }
        let controller = BrowserDownloadsPopoverViewController(
            downloads: downloads,
            onOpen: { [weak self] record in self?.onOpen?(record) },
            onReveal: { [weak self] record in self?.onReveal?(record) },
            onClear: { [weak self] in self?.onClear?() }
        )
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
    }
}

@MainActor
private final class BrowserDownloadsPopoverViewController: NSViewController {
    private let downloads: [BrowserDownloadRecord]
    private let onOpen: (BrowserDownloadRecord) -> Void
    private let onReveal: (BrowserDownloadRecord) -> Void
    private let onClear: () -> Void

    init(
        downloads: [BrowserDownloadRecord],
        onOpen: @escaping (BrowserDownloadRecord) -> Void,
        onReveal: @escaping (BrowserDownloadRecord) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.downloads = downloads
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onClear = onClear
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 340, height: downloads.isEmpty ? 112 : min(390, 52 + downloads.count * 58))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: String(localized: "browser.downloads.title", defaultValue: "Downloads"))
        title.font = .preferredFont(forTextStyle: .headline)
        let clear = BrowserDownloadActionButton(
            title: String(localized: "browser.downloads.clear", defaultValue: "Clear"),
            action: onClear
        )
        clear.isHidden = downloads.isEmpty
        let header = NSStackView(views: [title, NSView(), clear])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let content: NSView
        if downloads.isEmpty {
            let empty = NSTextField(labelWithString: String(
                localized: "browser.downloads.empty",
                defaultValue: "No recent downloads"
            ))
            empty.alignment = .center
            empty.textColor = .secondaryLabelColor
            empty.font = .preferredFont(forTextStyle: .callout)
            content = empty
        } else {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .width
            rows.spacing = 0
            for record in downloads {
                rows.addArrangedSubview(
                    BrowserDownloadRowView(record: record, onOpen: onOpen, onReveal: onReveal)
                )
            }
            rows.translatesAutoresizingMaskIntoConstraints = false

            let scrollView = NSScrollView()
            scrollView.documentView = rows
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            rows.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
            content = scrollView
        }
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 340),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: separator.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

@MainActor
private final class BrowserDownloadRowView: NSView {
    private let record: BrowserDownloadRecord
    private let onOpen: (BrowserDownloadRecord) -> Void

    init(
        record: BrowserDownloadRecord,
        onOpen: @escaping (BrowserDownloadRecord) -> Void,
        onReveal: @escaping (BrowserDownloadRecord) -> Void
    ) {
        self.record = record
        self.onOpen = onOpen
        super.init(frame: .zero)

        let icon = leadingIcon(for: record)
        let filename = NSTextField(labelWithString: record.filename)
        filename.lineBreakMode = .byTruncatingMiddle
        filename.maximumNumberOfLines = 1
        let subtitle = NSTextField(labelWithString: Self.subtitle(for: record))
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = record.state == .failed ? .systemRed : .secondaryLabelColor
        let labels = NSStackView(views: [filename, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(labels)
        if record.state == .saved {
            row.addArrangedSubview(BrowserDownloadActionButton(
                title: String(localized: "browser.downloads.open", defaultValue: "Open"),
                action: { onOpen(record) }
            ))
            let reveal = BrowserDownloadActionButton(
                imageName: "magnifyingglass",
                accessibilityLabel: String(
                    localized: "browser.downloads.showInFinder",
                    defaultValue: "Show in Finder"
                ),
                action: { onReveal(record) }
            )
            row.addArrangedSubview(reveal)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])

        if record.state == .saved {
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openRecord(_:))))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func leadingIcon(for record: BrowserDownloadRecord) -> NSView {
        if record.state == .downloading {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            return spinner
        }
        let symbol = record.state == .saved ? "doc.fill" : "exclamationmark.triangle.fill"
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = record.state == .failed ? .systemRed : .secondaryLabelColor
        image.imageScaling = .scaleProportionallyDown
        return image
    }

    @objc private func openRecord(_ sender: NSClickGestureRecognizer) {
        onOpen(record)
    }

    private static func subtitle(for record: BrowserDownloadRecord) -> String {
        switch record.state {
        case .downloading:
            return String(localized: "browser.downloading", defaultValue: "Downloading...")
        case .failed:
            return String(localized: "browser.downloads.failed", defaultValue: "Failed")
        case .saved:
            if let bytes = record.byteCount, bytes > 0 {
                return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            }
            return record.fileURL?.deletingLastPathComponent().lastPathComponent ?? ""
        }
    }
}

@MainActor
private final class BrowserDownloadActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        self.action = #selector(invoke(_:))
    }

    init(imageName: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityLabel)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        target = self
        self.action = #selector(invoke(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke(_ sender: NSButton) {
        handler()
    }
}
