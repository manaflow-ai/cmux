import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Native address-bar suggestions popup shared by portal-hosted and empty-tab
/// browser surfaces.
@MainActor
final class OmnibarSuggestionsView: NSView {
    private static let popupCornerRadius: CGFloat = 12
    private static let singleLineRowHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 1
    private static let topInset: CGFloat = 3
    private static let bottomInset: CGFloat = 3
    private static let maxPopupHeight: CGFloat = 560

    private let contentView = OmnibarSuggestionsFlippedView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let progressIndicator = NSProgressIndicator(frame: .zero)
    private let chromeView: NSView
    private var rowsByID: [String: OmnibarSuggestionRowView] = [:]
    private var orderedRows: [OmnibarSuggestionRowView] = []
    private var items: [OmnibarSuggestion] = []
    private var selectedIndex = 0
    private var onCommit: (OmnibarSuggestion) -> Void = { _ in }
    private var onHighlight: (Int) -> Void = { _ in }

    override var isFlipped: Bool { true }

    init(
        engineName: String,
        items: [OmnibarSuggestion],
        selectedIndex: Int,
        isLoadingRemoteSuggestions: Bool,
        searchSuggestionsEnabled: Bool,
        colorScheme: WindowChromeColorScheme,
        onCommit: @escaping (OmnibarSuggestion) -> Void,
        onHighlight: @escaping (Int) -> Void
    ) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Self.popupCornerRadius
            chromeView = glass
        } else {
            let visual = NSVisualEffectView()
            visual.material = .popover
            visual.blendingMode = .withinWindow
            visual.state = .active
            chromeView = visual
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.popupCornerRadius
        layer?.masksToBounds = false
        layer?.shadowRadius = 20
        layer?.shadowOffset = NSSize(width: 0, height: -10)
        layer?.shadowOpacity = colorScheme == .dark ? 0.45 : 0.18

        chromeView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.wantsLayer = true
        chromeView.layer?.cornerRadius = Self.popupCornerRadius
        chromeView.layer?.masksToBounds = true
        chromeView.layer?.borderWidth = 1
        addSubview(chromeView)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = contentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let chromeContent = NSView(frame: .zero)
        chromeContent.translatesAutoresizingMaskIntoConstraints = false
        chromeContent.addSubview(scrollView)
        chromeContent.addSubview(progressIndicator)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: chromeContent.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: chromeContent.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: chromeContent.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: chromeContent.bottomAnchor),
            progressIndicator.topAnchor.constraint(equalTo: chromeContent.topAnchor, constant: 7),
            progressIndicator.trailingAnchor.constraint(equalTo: chromeContent.trailingAnchor, constant: -14),
        ])

        if #available(macOS 26.0, *), let glass = chromeView as? NSGlassEffectView {
            glass.contentView = chromeContent
        } else {
            chromeView.addSubview(chromeContent)
            NSLayoutConstraint.activate([
                chromeContent.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
                chromeContent.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
                chromeContent.topAnchor.constraint(equalTo: chromeView.topAnchor),
                chromeContent.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeView.topAnchor.constraint(equalTo: topAnchor),
            chromeView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityIdentifier("BrowserOmnibarSuggestions")
        setAccessibilityLabel(String(
            localized: "browser.addressBarSuggestions",
            defaultValue: "Address bar suggestions"
        ))
        update(
            engineName: engineName,
            items: items,
            selectedIndex: selectedIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: searchSuggestionsEnabled,
            colorScheme: colorScheme,
            onCommit: onCommit,
            onHighlight: onHighlight
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func popupHeight(for items: [OmnibarSuggestion]) -> CGFloat {
        let totalRowCount = max(1, items.count)
        let rowsHeight = CGFloat(totalRowCount) * singleLineRowHeight
        let gaps = CGFloat(max(0, totalRowCount - 1)) * rowSpacing
        let height = min(
            max(rowsHeight + gaps + topInset + bottomInset, singleLineRowHeight + topInset + bottomInset),
            maxPopupHeight
        )
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (height * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    func update(
        engineName: String,
        items: [OmnibarSuggestion],
        selectedIndex: Int,
        isLoadingRemoteSuggestions: Bool,
        searchSuggestionsEnabled: Bool,
        colorScheme: WindowChromeColorScheme,
        onCommit: @escaping (OmnibarSuggestion) -> Void,
        onHighlight: @escaping (Int) -> Void
    ) {
        _ = engineName
        self.items = items
        self.selectedIndex = selectedIndex
        self.onCommit = onCommit
        self.onHighlight = onHighlight
        appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        layer?.shadowOpacity = colorScheme == .dark ? 0.45 : 0.18
        chromeView.layer?.borderColor = (
            colorScheme == .dark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.10)
        ).cgColor
        reconcileRows(colorScheme: colorScheme)
        if searchSuggestionsEnabled, isLoadingRemoteSuggestions {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rowsHeight = CGFloat(max(1, orderedRows.count)) * Self.singleLineRowHeight
            + CGFloat(max(0, orderedRows.count - 1)) * Self.rowSpacing
        let documentHeight = rowsHeight + Self.topInset + Self.bottomInset
        contentView.frame = NSRect(x: 0, y: 0, width: max(0, scrollView.contentSize.width), height: documentHeight)
        for (index, row) in orderedRows.enumerated() {
            row.frame = NSRect(
                x: Self.topInset,
                y: Self.topInset + CGFloat(index) * (Self.singleLineRowHeight + Self.rowSpacing),
                width: max(0, contentView.bounds.width - Self.topInset * 2),
                height: Self.singleLineRowHeight
            )
        }
        scrollView.hasVerticalScroller = documentHeight > Self.maxPopupHeight
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: Self.popupCornerRadius,
            cornerHeight: Self.popupCornerRadius,
            transform: nil
        )
    }

    private func reconcileRows(colorScheme: WindowChromeColorScheme) {
        var retained: [String: OmnibarSuggestionRowView] = [:]
        orderedRows = items.enumerated().map { index, item in
            let row = rowsByID[item.id] ?? OmnibarSuggestionRowView(frame: .zero)
            row.update(
                item: item,
                index: index,
                isSelected: index == selectedIndex,
                colorScheme: colorScheme,
                onCommit: { [weak self] item in self?.commit(item, index: index) },
                onHighlight: { [weak self] in self?.highlight(index) }
            )
            if row.superview !== contentView { contentView.addSubview(row) }
            retained[item.id] = row
            return row
        }
        for (id, row) in rowsByID where retained[id] == nil { row.removeFromSuperview() }
        rowsByID = retained
    }

    private func commit(_ item: OmnibarSuggestion, index: Int) {
#if DEBUG
        let kind: String = switch item.kind {
        case .search: "search"
        case .navigate: "navigate"
        case .history: "history"
        case .switchToTab: "switchToTab"
        case .remote: "remote"
        }
        cmuxDebugLog("browser.suggestionClick index=\(index) kind=\(kind) textBytes=\(item.listText.utf8.count)")
#endif
        onCommit(item)
    }

    private func highlight(_ index: Int) {
        guard index != selectedIndex, Self.isPointerDrivenSelectionEvent else { return }
        onHighlight(index)
    }

    private static var isPointerDrivenSelectionEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }
}

@MainActor
private final class OmnibarSuggestionRowView: NSControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var trackingAreaReference: NSTrackingArea?
    private var representedItem: OmnibarSuggestion?
    private var onCommit: (OmnibarSuggestion) -> Void = { _ in }
    private var onHighlight: () -> Void = {}

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        badgeLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 7
        target = self
        action = #selector(commitRepresentedItem)
        sendAction(on: .leftMouseUp)
        addSubview(titleLabel)
        addSubview(badgeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        item: OmnibarSuggestion,
        index: Int,
        isSelected: Bool,
        colorScheme: WindowChromeColorScheme,
        onCommit: @escaping (OmnibarSuggestion) -> Void,
        onHighlight: @escaping () -> Void
    ) {
        representedItem = item
        self.onCommit = onCommit
        self.onHighlight = onHighlight
        titleLabel.stringValue = item.listText
        titleLabel.textColor = colorScheme == .dark ? NSColor.white.withAlphaComponent(0.90) : .labelColor
        badgeLabel.stringValue = item.trailingBadgeText ?? ""
        badgeLabel.isHidden = item.trailingBadgeText == nil
        badgeLabel.textColor = colorScheme == .dark
            ? NSColor.white.withAlphaComponent(0.72)
            : .secondaryLabelColor
        badgeLabel.layer?.backgroundColor = (
            colorScheme == .dark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.06)
        ).cgColor
        layer?.backgroundColor = isSelected
            ? (colorScheme == .dark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.07)).cgColor
            : NSColor.clear.cgColor
        setAccessibilityIdentifier("BrowserOmnibarSuggestions.Row.\(index)")
        setAccessibilityValue(isSelected ? "selected \(item.listText)" : item.listText)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let badgeWidth: CGFloat
        if badgeLabel.isHidden {
            badgeWidth = 0
            badgeLabel.frame = .zero
        } else {
            badgeWidth = min(120, ceil(badgeLabel.intrinsicContentSize.width) + 12)
            badgeLabel.frame = NSRect(
                x: max(inset, bounds.width - inset - badgeWidth),
                y: 3,
                width: badgeWidth,
                height: 18
            )
        }
        titleLabel.frame = NSRect(
            x: inset,
            y: 4,
            width: max(0, bounds.width - inset * 2 - (badgeWidth > 0 ? badgeWidth + 6 : 0)),
            height: 16
        )
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHighlight() }
    override func mouseMoved(with event: NSEvent) { onHighlight() }

    @objc private func commitRepresentedItem() {
        guard let representedItem else { return }
        onCommit(representedItem)
    }
}

@MainActor
private final class OmnibarSuggestionsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
