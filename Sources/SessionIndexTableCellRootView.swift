import AppKit
import CmuxFoundation

/// Stable native content root owned by one recycled Vault table cell.
@MainActor
final class SessionIndexTableCellRootView: NSView, NSDraggingSource {
    private var row: SessionIndexTableRow?
    private var environment = SessionIndexTableEnvironmentSnapshot.fallback
    private var previewEntryID: SessionEntry.ID?
    private var entryViews: [SessionEntry.ID: SessionIndexEntryRowView] = [:]
    private var anchorIdentities: Set<SessionIndexTablePopoverIdentity> = []
    private var onPopoverAnchorChange: ((SessionIndexTablePopoverIdentity, CGRect?) -> Void)?
    private var headerButton: NSButton?
    private var showMoreButton: NSButton?
    private var gapIsTargeted = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        row: SessionIndexTableRow,
        environment: SessionIndexTableEnvironmentSnapshot,
        onPopoverAnchorChange: @escaping (SessionIndexTablePopoverIdentity, CGRect?) -> Void
    ) {
        clearAnchors()
        subviews.forEach { $0.removeFromSuperview() }
        entryViews.removeAll(keepingCapacity: true)
        headerButton = nil
        showMoreButton = nil
        self.row = row
        self.environment = environment
        self.previewEntryID = row.containedPreviewEntryID
        self.onPopoverAnchorChange = onPopoverAnchorChange
        alphaValue = 1

        switch row {
        case .gap:
            break
        case let .section(section, rowLimit, isDragged, _, isCollapsed, actions, _, _):
            alphaValue = isDragged ? 0.45 : 1
            let header = makeHeader(section: section, collapsed: isCollapsed)
            addSubview(header)
            headerButton = header
            guard !isCollapsed else { break }
            for entry in section.entries.prefix(rowLimit) {
                let entryView = SessionIndexEntryRowView(entry: entry, owner: self)
                entryView.isPreviewPresented = previewEntryID == entry.id
                addSubview(entryView)
                entryViews[entry.id] = entryView
            }
            if section.shouldOfferShowMore(rowLimit: rowLimit) {
                let button = NSButton(
                    title: String(localized: "sessionIndex.section.showMore", defaultValue: "Show more"),
                    target: self,
                    action: #selector(showMore)
                )
                button.isBordered = false
                button.alignment = .left
                button.font = scaledFont(size: 12, weight: .medium)
                button.contentTintColor = .secondaryLabelColor.withAlphaComponent(0.7)
                button.identifier = NSUserInterfaceItemIdentifier("SessionIndex.showMore")
                addSubview(button)
                showMoreButton = button
            }
            _ = actions
        }
        needsLayout = true
        needsDisplay = true
    }

    func updatePresentation(from row: SessionIndexTableRow) {
        self.row = row
        let next = row.containedPreviewEntryID
        guard next != previewEntryID else { return }
        previewEntryID = next
        for (id, view) in entryViews {
            view.isPreviewPresented = id == next
        }
    }

    override func layout() {
        super.layout()
        guard let row else { return }
        switch row {
        case .gap:
            break
        case let .section(section, _, _, _, isCollapsed, _, _, _):
            var y: CGFloat = 0
            let headerHeight = lineHeight(size: 13, minimum: 14, padding: 6)
            headerButton?.frame = NSRect(x: 0, y: y, width: bounds.width, height: headerHeight)
            y += headerHeight
            guard !isCollapsed else { return }
            let entryHeight = lineHeight(size: 13, minimum: 12, padding: 8)
            for entry in section.entries where entryViews[entry.id] != nil {
                guard let entryView = entryViews[entry.id] else { continue }
                entryView.frame = NSRect(x: 0, y: y, width: bounds.width, height: entryHeight)
                entryView.applyFontScale(environment.globalFontMagnificationPercent)
                reportAnchor(.transcript(section: section.key, entry: entry.id), frame: entryView.frame)
                y += entryHeight
            }
            if let showMoreButton {
                let height = lineHeight(size: 12, minimum: 0, padding: 8)
                showMoreButton.frame = NSRect(x: 32, y: y, width: max(0, bounds.width - 44), height: height)
                reportAnchor(.section(section.key), frame: showMoreButton.frame)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard case .gap? = row, gapIsTargeted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 10, y: max(0, bounds.midY - 1.5), width: max(0, bounds.width - 20), height: 3),
            xRadius: 1.5,
            yRadius: 1.5
        ).fill()
    }

    private func makeHeader(section: IndexSection, collapsed: Bool) -> NSButton {
        let button = NSButton(title: section.title, target: self, action: #selector(toggleCollapsed))
        button.isBordered = false
        button.alignment = .left
        button.font = scaledFont(size: 13)
        button.contentTintColor = .secondaryLabelColor
        button.lineBreakMode = .byTruncatingMiddle
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.image = sectionImage(section.icon)
        button.toolTip = section.title
        button.identifier = NSUserInterfaceItemIdentifier("SessionIndex.sectionHeader")
        button.setAccessibilityLabel(section.title)
        button.setAccessibilityRole(.button)
        button.setAccessibilityValue(collapsed ? "collapsed" : "expanded")
        return button
    }

    private func sectionImage(_ icon: SectionIcon) -> NSImage? {
        let image: NSImage?
        switch icon {
        case .folder:
            image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        case .agent(let agent):
            image = agent.assetName.flatMap { NSImage(named: NSImage.Name($0)) }
                ?? NSImage(systemSymbolName: agent.systemImageName ?? "person.crop.circle", accessibilityDescription: nil)
        }
        image?.size = NSSize(width: 14, height: 14)
        return image
    }

    private func scaledFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(size, percent: environment.globalFontMagnificationPercent),
            weight: weight
        )
    }

    private func lineHeight(size: CGFloat, minimum: CGFloat, padding: CGFloat) -> CGFloat {
        ceil(max(scaledFont(size: size).boundingRectForFont.height, minimum) + padding)
    }

    private func clearAnchors() {
        guard let onPopoverAnchorChange else {
            anchorIdentities.removeAll()
            return
        }
        for identity in anchorIdentities {
            onPopoverAnchorChange(identity, nil)
        }
        anchorIdentities.removeAll()
    }

    private func reportAnchor(_ identity: SessionIndexTablePopoverIdentity, frame: NSRect) {
        anchorIdentities.insert(identity)
        onPopoverAnchorChange?(identity, frame)
    }

    @objc private func toggleCollapsed() {
        guard case let .section(_, _, _, _, isCollapsed, _, setCollapsed, _) = row else { return }
        setCollapsed(!isCollapsed)
    }

    @objc private func showMore() {
        guard case let .section(_, _, _, _, _, _, _, setPopoverOpen) = row else { return }
        setPopoverOpen(true)
    }

    fileprivate func preview(_ entry: SessionEntry) {
        guard case let .section(_, _, _, _, _, actions, _, _) = row else { return }
        actions.onPreviewEntry(entry)
    }

    fileprivate func beginEntryDrag(_ entry: SessionEntry, event: NSEvent, sourceView: NSView) {
        let dragID = SessionDragRegistry.shared.register(entry)
        guard let data = sessionTabTransferData(for: entry, dragId: dragID) else { return }
        let type = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: sourceView.bounds.size)
        if let representation = sourceView.bitmapImageRepForCachingDisplay(in: sourceView.bounds) {
            sourceView.cacheDisplay(in: sourceView.bounds, to: representation)
            image.addRepresentation(representation)
        }
        draggingItem.setDraggingFrame(sourceView.frame, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    fileprivate func menu(for entry: SessionEntry) -> NSMenu {
        let menu = NSMenu()
        if case let .section(_, _, _, _, _, actions, _, _) = row, actions.onResume != nil {
            menu.addItem(actionItem(
                String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab"),
                action: #selector(resumeEntry), entry: entry
            ))
            menu.addItem(.separator())
        }
        if entry.fileURL != nil {
            menu.addItem(actionItem(String(localized: "sessionIndex.row.open", defaultValue: "Open"), action: #selector(openEntry), entry: entry))
            menu.addItem(actionItem(String(localized: "sessionIndex.row.reveal", defaultValue: "Reveal in Finder"), action: #selector(revealEntry), entry: entry))
            menu.addItem(.separator())
            menu.addItem(actionItem(String(localized: "sessionIndex.row.copyPath", defaultValue: "Copy File Path"), action: #selector(copyEntryPath), entry: entry))
        }
        if entry.resumeCommand != nil {
            menu.addItem(actionItem(String(localized: "sessionIndex.row.copyResume", defaultValue: "Copy Resume Command"), action: #selector(copyResumeCommand), entry: entry))
        }
        if entry.cwd?.isEmpty == false {
            menu.addItem(actionItem(String(localized: "sessionIndex.row.openCwd", defaultValue: "Open Working Directory"), action: #selector(openWorkingDirectory), entry: entry))
        }
        if entry.pullRequest.flatMap({ URL(string: $0.url) }) != nil {
            menu.addItem(.separator())
            menu.addItem(actionItem(String(localized: "sessionIndex.row.openPR", defaultValue: "Open Pull Request"), action: #selector(openPullRequest), entry: entry))
        }
        return menu
    }

    private func actionItem(_ title: String, action: Selector, entry: SessionEntry) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = SessionIndexEntryBox(entry)
        return item
    }

    private func entry(from sender: Any?) -> SessionEntry? {
        (sender as? NSMenuItem)?.representedObject.flatMap { ($0 as? SessionIndexEntryBox)?.entry }
    }

    @objc private func resumeEntry(_ sender: Any?) {
        guard let entry = entry(from: sender),
              case let .section(_, _, _, _, _, actions, _, _) = row else { return }
        actions.onResume?(entry)
    }

    @objc private func openEntry(_ sender: Any?) {
        guard let url = entry(from: sender)?.fileURL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func revealEntry(_ sender: Any?) {
        guard let url = entry(from: sender)?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func copyEntryPath(_ sender: Any?) { copy(entry(from: sender)?.fileURL?.path) }
    @objc private func copyResumeCommand(_ sender: Any?) { copy(entry(from: sender)?.resumeCommand) }
    @objc private func openWorkingDirectory(_ sender: Any?) {
        guard let cwd = entry(from: sender)?.cwd, !cwd.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }
    @objc private func openPullRequest(_ sender: Any?) {
        guard let raw = entry(from: sender)?.pullRequest?.url, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case let .gap(beforeKey, isValidDrop, actions)? = row,
              isValidDrop,
              sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.string.rawValue]),
              actions.currentDraggedKey() != beforeKey else { return [] }
        gapIsTargeted = true
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        gapIsTargeted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        gapIsTargeted = false
        needsDisplay = true
        guard case let .gap(beforeKey, _, actions)? = row,
              let raw = sender.draggingPasteboard.string(forType: .string) else {
            return false
        }
        actions.moveSection(SectionKey(raw: raw), beforeKey)
        actions.clearDraggedKey()
        return true
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

}

private final class SessionIndexEntryBox: NSObject {
    let entry: SessionEntry
    init(_ entry: SessionEntry) { self.entry = entry }
}

@MainActor
private final class SessionIndexEntryRowView: NSView {
    let entry: SessionEntry
    private weak var owner: SessionIndexTableCellRootView?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { updateBackground() } }
    var isPreviewPresented = false { didSet { updateBackground() } }

    override var isFlipped: Bool { true }

    init(entry: SessionEntry, owner: SessionIndexTableCellRootView) {
        self.entry = entry
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        iconView.imageScaling = .scaleProportionallyDown
        iconView.image = entry.agent.assetName.flatMap { NSImage(named: NSImage.Name($0)) }
            ?? NSImage(systemSymbolName: entry.agent.systemImageName ?? "person.crop.circle", accessibilityDescription: nil)
        titleLabel.stringValue = entry.displayTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        timeLabel.stringValue = Self.relativeFormatter.localizedString(for: entry.modified, relativeTo: Date())
        timeLabel.alignment = .right
        timeLabel.textColor = .secondaryLabelColor.withAlphaComponent(0.65)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(timeLabel)
        toolTip = Self.helpText(entry)
        setAccessibilityLabel(entry.displayTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyFontScale(_ percent: Int) {
        titleLabel.font = .systemFont(ofSize: GlobalFontMagnification.scaledSize(13, percent: percent))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: GlobalFontMagnification.scaledSize(12, percent: percent), weight: .regular)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let content = bounds.insetBy(dx: 12, dy: 4)
        iconView.frame = NSRect(x: 32, y: content.minY + max(0, (content.height - 12) / 2), width: 12, height: 12)
        let timeWidth = ceil(timeLabel.intrinsicContentSize.width)
        timeLabel.frame = NSRect(x: max(50, bounds.width - 12 - timeWidth), y: content.minY, width: timeWidth, height: content.height)
        titleLabel.frame = NSRect(x: 50, y: content.minY, width: max(0, timeLabel.frame.minX - 58), height: content.height)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.preview(entry) }
    }
    override func mouseDragged(with event: NSEvent) { owner?.beginEntryDrag(entry, event: event, sourceView: self) }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(for: entry) }

    private func updateBackground() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovering ? 0.05 : (isPreviewPresented ? 0.07 : 0)).cgColor
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func helpText(_ entry: SessionEntry) -> String {
        var lines = [entry.displayTitle]
        if let cwd = entry.cwdLabel { lines.append(cwd) }
        lines.append(absoluteFormatter.string(from: entry.modified))
        return lines.joined(separator: "\n")
    }
}
