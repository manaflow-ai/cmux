#if os(macOS)
import AppKit
import CmuxConversationCore

/// Transcript table that routes trackpad horizontal swipes and clicks on
/// row accessories (badges, footers) back to the controller.
final class MacTranscriptTableView: NSTableView {
    weak var interaction: MacConversationViewController?

    override func scrollWheel(with event: NSEvent) {
        if interaction?.handleHorizontalScroll(event, in: self) == true { return }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if interaction?.handleClick(event, in: self) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        interaction?.contextMenu(for: event, in: self)
    }
}

/// A Messages-style conversation for macOS over any `ConversationBackend`.
public final class MacConversationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, MacComposerViewDelegate {
    public let store: ConversationStore
    private let serviceTitle: String

    let scrollView = NSScrollView()
    let tableView = MacTranscriptTableView()
    let composer = MacComposerView()
    /// The window puts the composer in its bottom accessory and the title in its toolbar.
    var onComposerHeightChange: (() -> Void)?
    var onInfoChange: ((ConversationInfo, String?, Bool) -> Void)?
    let layoutCache = MacMessageLayoutCache()
    private let initialSpinner = NSProgressIndicator()
    private let topEdge = NSVisualEffectView()
    private let topEdgeMask = CAGradientLayer()
    private let topEdgeTint = NSView()
    private let topEdgeTintMask = CAGradientLayer()

    private(set) var rows: [MacConversationRow] = []
    private var rowIndex: [String: Int] = [:]
    private var hasPositioned = false
    private var isPinnedToBottom = true
    private var pendingSendRowID: String?
    private var arrivingRowIDs: Set<String> = []
    private var lastWidth: CGFloat = 0
    private var isLiveScrolling = false

    // Reply / edit state.
    private var replyTarget: ConversationMessage?
    private var replyFocus: MacReplyFocusView?
    private var editingMessageID: String?
    private let replyBanner = MacReplyBanner()

    // Swipe state.
    private var swipeAccumulatedX: CGFloat = 0
    private var swipeRowID: String?
    private var timestampsRevealed: CGFloat = 0

    public init(store: ConversationStore, serviceTitle: String = "iMessage") {
        self.store = store
        self.serviceTitle = serviceTitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = MacFlippedView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        root.layer?.backgroundColor = nil
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.interaction = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self
        tableView.setAccessibilityIdentifier("conversation.transcript")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MacConversationTheme.background
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        composer.delegate = self
        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        replyBanner.isHidden = true
        replyBanner.onClose = { [weak self] in self?.exitReplyOrEdit() }
        view.addSubview(replyBanner)

        // Soft top edge: content scrolling under the toolbar blurs and fades,
        // matching the system scroll edge effect Messages shows there.
        topEdge.material = .headerView
        topEdge.blendingMode = .withinWindow
        topEdge.state = .active
        topEdge.wantsLayer = true
        topEdge.layer?.mask = topEdgeMask
        topEdgeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        topEdgeMask.locations = [0, 0.55, 1]
        topEdgeTint.wantsLayer = true
        topEdgeTint.layer?.mask = topEdgeTintMask
        topEdgeTintMask.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        topEdgeTintMask.locations = [0, 0.45, 1]
        view.addSubview(topEdge)
        view.addSubview(topEdgeTint)

        initialSpinner.style = .spinning
        initialSpinner.controlSize = .regular
        initialSpinner.translatesAutoresizingMaskIntoConstraints = false
        initialSpinner.setAccessibilityIdentifier("conversation.initialLoading")
        view.addSubview(initialSpinner)
        initialSpinner.startAnimation(nil)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            // The content pane extends under the floating sidebar; the transcript starts beside it.
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            replyBanner.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            replyBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            replyBanner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            replyBanner.heightAnchor.constraint(equalToConstant: 30),
            initialSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            initialSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        store.onChange = { [weak self] change in self?.storeDidChange(change) }
        store.start()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(composer.textView)
        if hasPositioned, isPinnedToBottom { scrollToBottom() }
    }


    public override func viewDidLayout() {
        super.viewDidLayout()
        let edgeHeight = view.safeAreaInsets.top + 18
        // Starts above the view so the band reaches the window's top edge.
        let edgeFrame = CGRect(x: view.safeAreaInsets.left, y: -40, width: view.bounds.width - view.safeAreaInsets.left, height: edgeHeight + 40)
        topEdge.frame = edgeFrame
        topEdgeTint.frame = edgeFrame
        topEdgeMask.frame = topEdge.bounds
        topEdgeTintMask.frame = topEdgeTint.bounds
        topEdgeTint.layer?.backgroundColor = resolved(MacConversationTheme.background, in: view)
        updateInsets()
        let width = scrollView.contentSize.width
        // One column, exactly as wide as the visible transcript.
        if let column = tableView.tableColumns.first, column.width != width {
            column.width = width
        }
        if width != lastWidth {
            // Live resize reflows bubbles; keep the bottom pinned or the reader's anchor fixed.
            let anchor = captureAnchor()
            lastWidth = width
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            if isPinnedToBottom { scrollToBottom() } else { restore(anchor) }
        }
        composer.maximumFieldHeight = max(28, view.bounds.height * 0.45)
        // Row heights settle in layout passes; a pinned reader stays on the newest message.
        if hasPositioned, isPinnedToBottom, !isLiveScrolling { scrollToBottom() }
    }

    private func updateInsets() {
        // The toolbar and the composer accessory arrive as safe-area insets.
        let top = view.safeAreaInsets.top
        let bottom = view.safeAreaInsets.bottom + (replyBanner.isHidden ? 0 : 30) + 8
        let content = tableView.bounds.height
        let visible = scrollView.bounds.height - top - bottom
        // Short transcripts sit at the bottom, like Messages.
        let spacer = max(0, visible - content)
        let insets = NSEdgeInsets(top: top + spacer, left: 0, bottom: bottom, right: 0)
        let old = scrollView.contentInsets
        guard old.top != insets.top || old.bottom != insets.bottom else { return }
        scrollView.contentInsets = insets
        scrollView.scrollerInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if isPinnedToBottom, hasPositioned { scrollToBottom() }
    }

    // MARK: Scrolling

    /// The width every row lays out against (the visible clip width).
    var transcriptWidth: CGFloat { max(200, scrollView.contentSize.width) }

    private var maxOffset: CGFloat {
        max(-scrollView.contentInsets.top, tableView.bounds.height - scrollView.contentSize.height + scrollView.contentInsets.bottom)
    }

    private func isNearBottom(_ tolerance: CGFloat = 40) -> Bool {
        scrollView.contentView.bounds.origin.y >= maxOffset - tolerance
    }

    func scrollToBottom(animated: Bool = false) {
        let target = NSPoint(x: 0, y: maxOffset)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scrollView.contentView.scroll(to: target)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func liveScrollStarted() { isLiveScrolling = true }

    @objc private func liveScrollEnded() {
        isLiveScrolling = false
        isPinnedToBottom = isNearBottom()
    }

    @objc private func boundsDidChange() {
        let origin = scrollView.contentView.bounds.origin.y
        if NSEvent.pressedMouseButtons != 0 || isLiveScrolling {
            isPinnedToBottom = isNearBottom()
        }
        if origin + scrollView.contentInsets.top < scrollView.contentSize.height * 1.5 {
            store.loadOlder()
        } else if origin + scrollView.contentInsets.top > scrollView.contentSize.height * 3 {
            store.olderNoLongerWanted()
        }
        if isNearBottom(60) { store.markNewestRead() }
    }

    private struct Anchor {
        var rowID: String
        var offset: CGFloat
    }

    private func bubbleTop(_ index: Int) -> CGFloat? {
        guard index < rows.count, case let .message(model) = rows[index] else { return nil }
        let rect = tableView.rect(ofRow: index)
        return rect.minY + layoutCache.layout(model, width: transcriptWidth).contentFrame.minY
    }

    private func captureAnchor() -> Anchor? {
        let visible = scrollView.contentView.bounds
        let top = visible.minY + scrollView.contentInsets.top
        let range = tableView.rows(in: visible)
        for index in range.location..<min(rows.count, range.location + range.length) {
            guard rows[index].isMessage, tableView.rect(ofRow: index).maxY > top, let y = bubbleTop(index) else { continue }
            return Anchor(rowID: rows[index].id, offset: y - visible.minY)
        }
        return nil
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let index = rowIndex[anchor.rowID], let y = bubbleTop(index) else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(-scrollView.contentInsets.top, y - anchor.offset), maxOffset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Store changes

    private func storeDidChange(_ change: ConversationStoreChange) {
        if store.hasLoadedNewest, !initialSpinner.isHidden {
            initialSpinner.stopAnimation(nil)
            initialSpinner.isHidden = true
        }
        if let info = store.info { onInfoChange?(info, store.meID, store.connection == .connected) }
        if case .connection = change { return }

        let newRows = MacConversationRowBuilder.rows(store: store)
        let oldIDs = Set(rowIndex.keys)
        let wasAtBottom = isPinnedToBottom || isNearBottom()
        let anchor = captureAnchor()
        var sentByMe = false
        if case let .live(inserted, mine) = change { sentByMe = mine && !inserted.isEmpty }
        if case .live = change {
            for row in newRows where !oldIDs.contains(row.id) {
                if case let .message(model) = row, !model.isOutgoing { arrivingRowIDs.insert(model.rowID) }
            }
        }
        rows = newRows
        rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        updateInsets()

        if !hasPositioned {
            if store.hasLoadedNewest, !rows.isEmpty {
                hasPositioned = true
                view.layoutSubtreeIfNeeded()
                scrollToBottom()
            }
            return
        }
        if sentByMe {
            isPinnedToBottom = true
            scrollToBottom(animated: true)
        } else if case .live = change, wasAtBottom {
            scrollToBottom(animated: true)
        } else if isPinnedToBottom, change != .prepended {
            // Status, typing and rebase changes keep a pinned reader at the bottom.
            scrollToBottom()
        } else {
            restore(anchor)
        }
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case let .message(model):
            let layout = layoutCache.layout(model, width: transcriptWidth)
            let spacing = row > 0 && rows[row - 1].isMessage
                ? (model.isFirstInRun ? MacConversationTheme.runSpacing : MacConversationTheme.groupedSpacing) : 4
            return layout.height + spacing
        case .timestamp: return MacTimestampRowView.height
        case .loadingOlder: return MacSpinnerRowView.height
        case .conversationStart: return MacConversationStartRowView.height
        case .typing: return MacTypingRowView.height
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .message(model):
            let view = tableView.makeView(withIdentifier: .init("m"), owner: nil) as? MacMessageContainerView ?? MacMessageContainerView()
            view.identifier = .init("m")
            let spacing = row > 0 && rows[row - 1].isMessage
                ? (model.isFirstInRun ? MacConversationTheme.runSpacing : MacConversationTheme.groupedSpacing) : 4
            view.topSpacing = spacing
            view.row.configure(model, layout: layoutCache.layout(model, width: transcriptWidth), text: layoutCache.text(model))
            view.timestampReveal = timestampsRevealed
            animateIfNeeded(view, model: model)
            return view
        case let .timestamp(_, date):
            let view = tableView.makeView(withIdentifier: .init("t"), owner: nil) as? MacTimestampRowView ?? MacTimestampRowView()
            view.identifier = .init("t")
            view.configure(date: date)
            return view
        case .loadingOlder:
            let view = tableView.makeView(withIdentifier: .init("l"), owner: nil) as? MacSpinnerRowView ?? MacSpinnerRowView()
            view.identifier = .init("l")
            return view
        case .conversationStart:
            let view = tableView.makeView(withIdentifier: .init("s"), owner: nil) as? MacConversationStartRowView ?? MacConversationStartRowView()
            view.identifier = .init("s")
            view.configure(title: serviceTitle, subtitle: String(localized: "conversation.start.encrypted", defaultValue: "Encrypted", bundle: .module))
            return view
        case let .typing(ids):
            let view = tableView.makeView(withIdentifier: .init("y"), owner: nil) as? MacTypingRowView ?? MacTypingRowView()
            view.identifier = .init("y")
            view.showsAvatar = store.info?.kind == .group
            view.avatar.initials = ids.first.flatMap { store.info?.participant($0)?.initials } ?? ""
            return view
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// Sends slide up from the composer; arrivals grow from their tail corner.
    private func animateIfNeeded(_ view: MacMessageContainerView, model: MacMessageRowModel) {
        guard let layer = view.row.layer else { return }
        if model.rowID == pendingSendRowID {
            pendingSendRowID = nil
            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 46
            rise.toValue = 0
            rise.damping = 18
            rise.stiffness = 320
            rise.mass = 1
            rise.duration = rise.settlingDuration
            layer.add(rise, forKey: "send")
        } else if arrivingRowIDs.remove(model.rowID) != nil {
            let content = view.row.contentFrame
            layer.anchorPoint = .zero
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.8
            pop.toValue = 1
            pop.damping = 16
            pop.stiffness = 260
            pop.duration = pop.settlingDuration
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            _ = content
            layer.add(pop, forKey: "arrive")
            layer.add(fade, forKey: "arriveFade")
        }
    }

    func messageModel(at row: Int) -> MacMessageRowModel? {
        guard row >= 0, row < rows.count, case let .message(model) = rows[row] else { return nil }
        return model
    }

    func rowView(at row: Int) -> MacMessageRowView? {
        (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MacMessageContainerView)?.row
    }

    // MARK: Composer

    func composerDidChangeText(_ composer: MacComposerView) {
        store.composerTextChanged(isEmpty: composer.text.isEmpty)
    }

    func composerDidChangeHeight(_ composer: MacComposerView) {
        onComposerHeightChange?()
        view.layoutSubtreeIfNeeded()
        updateInsets()
    }

    func composerDidSubmit(_ composer: MacComposerView) {
        if let messageID = editingMessageID {
            store.edit(messageID: messageID, text: composer.text)
            exitReplyOrEdit()
            composer.clearAfterSend()
            return
        }
        let images = composer.attachments.map { attachment in
            (data: attachment.data, width: Int(attachment.image.size.width), height: Int(attachment.image.size.height), mimeType: attachment.mimeType)
        }
        let replyTo = replyTarget?.id
        let text = composer.text
        composer.clearAfterSend()
        pendingSendRowID = store.send(text: text, images: images, replyToID: replyTo)
        if replyTarget != nil { exitReplyOrEdit(sent: true) }
    }

    func composerDidTapApps(_ composer: MacComposerView) {
        let menu = NSMenu()
        let photos = NSMenuItem(title: String(localized: "conversation.apps.photos", defaultValue: "Photos", bundle: .module), action: #selector(choosePhotos), keyEquivalent: "")
        photos.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        photos.target = self
        menu.addItem(photos)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: composer.appsButton.bounds.height + 4), in: composer.appsButton)
    }

    @objc private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { if let image = NSImage(contentsOf: url) { self?.composer.addImage(image) } }
        }
    }

    // MARK: Reply / edit

    func enterReply(_ message: ConversationMessage) {
        editingMessageID = nil
        replyTarget = message
        composer.isReplyMode = true
        composer.isEditMode = false
        replyBanner.isHidden = true
        updateInsets()
        showReplyFocus(for: message)
        view.window?.makeFirstResponder(composer.textView)
    }

    /// Messages' reply mode: the transcript blurs behind a lifted copy of the
    /// message being answered, which springs down to sit on the composer.
    private func showReplyFocus(for message: ConversationMessage) {
        replyFocus?.removeFromSuperview()
        guard let index = rows.firstIndex(where: { if case let .message(model) = $0 { return model.message.id == message.id } else { return false } }),
              let row = rowView(at: index) else { return }
        let focus = MacReplyFocusView(frame: scrollView.frame)
        focus.messageID = message.id
        focus.autoresizingMask = [.width, .height]
        focus.onDismiss = { [weak self] in self?.exitReplyOrEdit() }
        view.addSubview(focus, positioned: .above, relativeTo: scrollView)
        let source = row.convert(row.bounds, to: focus)
        let bottomInset = view.safeAreaInsets.bottom + 10
        var target = source
        target.origin.y = focus.isFlipped ? focus.bounds.height - bottomInset - source.height : bottomInset
        focus.present(snapshotOf: row, from: source, to: target)
        replyFocus = focus
    }

    private func dismissReplyFocus(sent: Bool) {
        guard let focus = replyFocus else { return }
        replyFocus = nil
        var destination: CGRect?
        if !sent, let message = focus.messageID,
           let index = rows.firstIndex(where: { if case let .message(model) = $0 { return model.message.id == message } else { return false } }),
           let row = rowView(at: index) {
            destination = row.convert(row.bounds, to: focus)
        }
        focus.dismiss(returningTo: destination)
    }

    func enterEdit(_ message: ConversationMessage) {
        replyTarget = nil
        editingMessageID = message.id
        composer.isReplyMode = false
        composer.isEditMode = true
        composer.text = message.text
        replyBanner.configure(title: String(localized: "conversation.menu.edit", defaultValue: "Edit", bundle: .module), text: message.text)
        replyBanner.isHidden = false
        updateInsets()
        view.window?.makeFirstResponder(composer.textView)
    }

    func exitReplyOrEdit(sent: Bool = false) {
        dismissReplyFocus(sent: sent)
        if editingMessageID != nil { composer.clearAfterSend() }
        replyTarget = nil
        editingMessageID = nil
        composer.isReplyMode = false
        composer.isEditMode = false
        replyBanner.isHidden = true
        updateInsets()
    }

    public override func cancelOperation(_ sender: Any?) {
        exitReplyOrEdit()
    }

    // MARK: Interaction

    private func row(at event: NSEvent, in table: NSTableView) -> (Int, NSPoint)? {
        let point = table.convert(event.locationInWindow, from: nil)
        let index = table.row(at: point)
        guard index >= 0 else { return nil }
        return (index, point)
    }

    func handleClick(_ event: NSEvent, in table: NSTableView) -> Bool {
        guard event.clickCount == 1, let (index, point) = row(at: event, in: table),
              let model = messageModel(at: index), let rowView = rowView(at: index) else { return false }
        let local = rowView.convert(point, from: table)
        if !rowView.failedBadge.isHidden, rowView.failedBadge.frame.insetBy(dx: -6, dy: -6).contains(local) {
            showRetryMenu(model, at: local, in: rowView)
            return true
        }
        if !rowView.badge.isHidden, rowView.badge.frame.insetBy(dx: -4, dy: -4).contains(local) {
            showReactors(model, from: rowView.badge)
            return true
        }
        if !rowView.repliesLabel.isHidden, rowView.repliesLabel.frame.contains(local) {
            showThread(rootID: model.message.id, from: rowView.repliesLabel)
            return true
        }
        if let text = rowView.rowLayout?.textFrame, text.contains(local),
           let url = link(in: model, at: CGPoint(x: local.x - text.minX, y: local.y - text.minY), width: text.width) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    private func link(in model: MacMessageRowModel, at point: CGPoint, width: CGFloat) -> URL? {
        let text = layoutCache.text(model)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < text.length else { return nil }
        return text.attribute(.macConversationLink, at: index, effectiveRange: nil) as? URL
    }

    @objc private func tableDoubleClicked() {
        let index = tableView.clickedRow
        guard let model = messageModel(at: index), let rowView = rowView(at: index) else { return }
        showTapbackBar(model, in: rowView)
    }

    func showTapbackBar(_ model: MacMessageRowModel, in rowView: MacMessageRowView) {
        let popover = NSPopover()
        popover.behavior = .transient
        let mine = model.message.reactions.first { $0.participantID == store.meID }?.reaction
        popover.contentViewController = MacTapbackBarController(current: mine) { [weak self, weak popover] reaction in
            popover?.close()
            self?.store.react(messageID: model.message.id, reaction: mine == reaction ? nil : reaction)
        }
        popover.show(relativeTo: rowView.contentFrame, of: rowView, preferredEdge: .maxY)
    }

    func contextMenu(for event: NSEvent, in table: NSTableView) -> NSMenu? {
        guard let (index, _) = row(at: event, in: table), let model = messageModel(at: index), let rowView = rowView(at: index) else { return nil }
        let message = model.message
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = MacClosureMenuItem(title: title, handler: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
        menu.addItem(item(String(localized: "conversation.menu.reply", defaultValue: "Reply", bundle: .module), "arrowshape.turn.up.left") { [weak self] in self?.enterReply(message) })
        menu.addItem(item(String(localized: "conversation.menu.tapback", defaultValue: "Tapback…", bundle: .module), "heart") { [weak self] in self?.showTapbackBar(model, in: rowView) })
        if store.canEdit(message) {
            menu.addItem(item(String(localized: "conversation.menu.edit", defaultValue: "Edit", bundle: .module), "pencil") { [weak self] in self?.enterEdit(message) })
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "conversation.menu.copy", defaultValue: "Copy", bundle: .module), "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        })
        if message.delivery?.isFailed == true {
            menu.addItem(item(String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module), "arrow.clockwise") { [weak self] in self?.store.retry(rowID: model.rowID) })
            menu.addItem(item(String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module), "trash") { [weak self] in self?.store.discardFailed(rowID: model.rowID) })
        }
        return menu
    }

    private func showRetryMenu(_ model: MacMessageRowModel, at point: NSPoint, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module)) { [weak self] in
            self?.store.retry(rowID: model.rowID)
        })
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module)) { [weak self] in
            self?.store.discardFailed(rowID: model.rowID)
        })
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func showReactors(_ model: MacMessageRowModel, from view: NSView) {
        let lines = model.message.reactions.compactMap { mark -> String? in
            guard let participant = store.info?.participant(mark.participantID) else { return nil }
            let name = participant.isMe ? String(localized: "conversation.reaction.you", defaultValue: "You", bundle: .module) : participant.name
            return "\(MacTapbackGlyph.text(mark.reaction).string.replacingOccurrences(of: "\n", with: " "))  \(name)"
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = MacTextPopoverController(text: lines.joined(separator: "\n"))
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private func showThread(rootID: String, from view: NSView) {
        let thread = store.messages.filter { $0.id == rootID || $0.replyToID == rootID }
        let lines = thread.map { message -> String in
            let name = store.info?.participant(message.senderID)?.name ?? ""
            return "\(name): \(message.text)"
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = MacTextPopoverController(text: lines.joined(separator: "\n\n"))
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        if let root = thread.first { enterReply(root) }
    }

    // MARK: Lab automation (DEBUG dev runner only)

    #if DEBUG
    /// Drives the same paths a person uses, for scripted verification.
    public func labCommand(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return "error empty" }
        let argument = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "type":
            view.window?.makeFirstResponder(composer.textView)
            composer.textView.insertText(argument.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: composer.textView.selectedRange())
            return "ok"
        case "send":
            composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            return "ok"
        case "top":
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isPinnedToBottom = false
            boundsDidChange()
            return "ok"
        case "bottom":
            isPinnedToBottom = true
            scrollToBottom()
            return "ok"
        case "scroll":
            let dy = CGFloat(Double(argument) ?? 0)
            let y = min(max(-scrollView.contentInsets.top, scrollView.contentView.bounds.origin.y + dy), maxOffset)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isPinnedToBottom = isNearBottom()
            boundsDidChange()
            return "ok"
        case "rows":
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            let ids = (visible.location..<min(rows.count, visible.location + visible.length)).compactMap { messageModel(at: $0)?.message.id }
            return "visible \(ids.joined(separator: ","))"
        case "tapback", "menu", "reply", "edit":
            guard let index = lastMessageRow(matching: argument), let model = messageModel(at: index) else { return "error no row" }
            tableView.scrollRowToVisible(index)
            guard let rowView = rowView(at: index) else { return "error not visible" }
            switch verb {
            case "tapback": showTapbackBar(model, in: rowView)
            case "reply": enterReply(model.message)
            case "edit": enterEdit(model.message)
            default:
                let point = NSPoint(x: rowView.contentFrame.midX, y: rowView.contentFrame.midY)
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: rowView.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                if let event, let menu = contextMenu(for: event, in: tableView) {
                    return "menu " + menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: "|")
                }
            }
            return "ok"
        case "react":
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2, let index = lastMessageRow(matching: bits[0]), let model = messageModel(at: index),
                  let reaction = ConversationReaction(rawValue: bits[1]) else { return "error usage react <row-match> <reaction>" }
            store.react(messageID: model.message.id, reaction: reaction)
            return "ok"
        case "escape":
            exitReplyOrEdit()
            return "ok"
        default:
            return "error unknown verb"
        }
    }

    /// `mine` (newest outgoing), `last` (newest message), or a text substring.
    private func lastMessageRow(matching query: String) -> Int? {
        rows.indices.reversed().first { index in
            guard let model = messageModel(at: index) else { return false }
            switch query {
            case "mine": return model.isOutgoing && model.message.seq != nil
            case "last", "": return true
            default: return model.message.text.contains(query)
            }
        }
    }
    #endif

    // MARK: Trackpad swipes

    /// Two-finger swipe right on a bubble replies; swipe left reveals times.
    func handleHorizontalScroll(_ event: NSEvent, in table: NSTableView) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        switch event.phase {
        case .began:
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            swipeAccumulatedX = 0
            swipeRowID = row(at: event, in: table).flatMap { messageModel(at: $0.0)?.rowID }
            return true
        case .changed:
            guard swipeRowID != nil || swipeAccumulatedX != 0 || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            swipeAccumulatedX += event.scrollingDeltaX
            if swipeAccumulatedX > 0, let id = swipeRowID, let index = rowIndex[id],
               let container = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacMessageContainerView {
                container.replyDrag = min(80, swipeAccumulatedX * 0.8)
            } else if swipeAccumulatedX < 0 {
                setTimestampReveal(min(1, -swipeAccumulatedX / 60))
            }
            return true
        case .ended, .cancelled:
            if let id = swipeRowID, let index = rowIndex[id],
               let container = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacMessageContainerView {
                let commit = container.replyDrag >= 50 && event.phase == .ended
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    container.animator().replyDrag = 0
                }
                if commit, let model = messageModel(at: index) { enterReply(model.message) }
            }
            setTimestampReveal(0, animated: true)
            swipeRowID = nil
            swipeAccumulatedX = 0
            return true
        default:
            return false
        }
    }

    private func setTimestampReveal(_ value: CGFloat, animated: Bool = false) {
        timestampsRevealed = value
        let apply = {
            for index in 0..<self.rows.count {
                guard let container = self.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacMessageContainerView else { continue }
                if animated { container.animator().timestampReveal = value } else { container.timestampReveal = value }
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                apply()
            }
        } else {
            apply()
        }
    }
}

/// Hosts a message row with its top spacing, swipe offsets and revealed time.
final class MacMessageContainerView: MacFlippedView {
    let row = MacMessageRowView()
    private let timeLabel = makeMacLabel()
    var topSpacing: CGFloat = 0 { didSet { needsLayout = true } }
    @objc dynamic var replyDrag: CGFloat = 0 { didSet { needsLayout = true } }
    @objc dynamic var timestampReveal: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(row)
        timeLabel.font = MacConversationTheme.timestampFont
        timeLabel.textColor = MacConversationTheme.secondaryText
        addSubview(timeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "replyDrag" || key == "timestampReveal" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override func layout() {
        super.layout()
        let reveal = timestampReveal * 64
        let isOutgoing = row.model?.isOutgoing ?? false
        let shift = replyDrag - (isOutgoing ? reveal : 0)
        row.frame = CGRect(x: shift, y: topSpacing, width: bounds.width, height: bounds.height - topSpacing)
        timeLabel.stringValue = row.model?.message.sentAt.formatted(date: .omitted, time: .shortened) ?? ""
        timeLabel.sizeToFit()
        let content = row.contentFrame
        timeLabel.frame.origin = CGPoint(x: bounds.width - reveal + 6, y: topSpacing + content.midY - timeLabel.frame.height / 2)
        timeLabel.alphaValue = timestampReveal
    }
}

final class MacClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// The glass tapback bar shown on double-click or from the menu.
final class MacTapbackBarController: NSViewController {
    private let current: ConversationReaction?
    private let onPick: (ConversationReaction) -> Void

    init(current: ConversationReaction?, onPick: @escaping (ConversationReaction) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for reaction in ConversationReaction.allCases {
            let button = NSButton(title: "", target: self, action: #selector(picked(_:)))
            button.isBordered = false
            let glyph = NSMutableAttributedString(attributedString: MacTapbackGlyph.text(reaction))
            glyph.addAttribute(.font, value: NSFont.systemFont(ofSize: reaction == .haha ? 8 : 18, weight: .black), range: NSRange(location: 0, length: glyph.length))
            button.attributedTitle = glyph
            button.tag = ConversationReaction.allCases.firstIndex(of: reaction) ?? 0
            button.wantsLayer = true
            button.layer?.cornerRadius = 14
            if reaction == current { button.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor }
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.setAccessibilityLabel(reaction.rawValue)
            button.setAccessibilityIdentifier("conversation.tapback.\(reaction.rawValue)")
            stack.addArrangedSubview(button)
        }
        view = stack
    }

    @objc private func picked(_ sender: NSButton) {
        onPick(ConversationReaction.allCases[sender.tag])
    }
}

final class MacTextPopoverController: NSViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 300
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container
    }
}

/// "Replying to…" / "Editing" strip above the composer with a close button.
final class MacReplyBanner: MacFlippedView {
    private let label = makeMacLabel()
    private let close = NSButton()
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "conversation.header.close", defaultValue: "Close", bundle: .module))
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        addSubview(close)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, text: String) {
        label.stringValue = "\(title): \(text)"
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 52, y: 8, width: bounds.width - 52 - 40, height: 15)
        close.frame = CGRect(x: bounds.width - 32, y: 6, width: 18, height: 18)
    }

    @objc private func closeTapped() { onClose?() }
}

#endif

/// The reply-mode backdrop: a within-window blur over the transcript with a
/// snapshot of the answered message lifted above it. Clicking the blur cancels.
final class MacReplyFocusView: NSView {
    var onDismiss: (() -> Void)?
    var messageID: String?
    private let blur = NSVisualEffectView()
    private let snapshotView = MacFlippedView()
    private var snapshot: CALayer { snapshotView.layer! }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.material = .underWindowBackground
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        blur.alphaValue = 0
        addSubview(blur)
        addSubview(snapshotView)
        setAccessibilityIdentifier("conversation.replyFocus")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !snapshotView.frame.contains(point) { onDismiss?() }
    }

    // AppKit-backed layers anchor at their origin, so position == frame origin.
    func present(snapshotOf row: NSView, from source: CGRect, to target: CGRect) {
        // Render the layer tree: bubbles are CALayers that cacheDisplay skips.
        let scale = window?.backingScaleFactor ?? 2
        let size = row.bounds.size
        if let layer = row.layer, size.width > 0, size.height > 0,
           let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            NSAppearance.current = row.effectiveAppearance
            layer.render(in: context)
            snapshot.contents = context.makeImage()
        }
        snapshot.contentsScale = scale
        snapshotView.frame = target
        let lift = CASpringAnimation(keyPath: "position")
        lift.fromValue = NSValue(point: source.origin)
        lift.toValue = NSValue(point: target.origin)
        lift.damping = 26
        lift.stiffness = 300
        lift.mass = 1
        lift.duration = lift.settlingDuration
        snapshot.add(lift, forKey: "lift")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            blur.animator().alphaValue = 1
        }
    }

    func dismiss(returningTo destination: CGRect?) {
        if let destination {
            let current = snapshot.presentation()?.position ?? snapshot.position
            snapshotView.frame = destination
            let drop = CASpringAnimation(keyPath: "position")
            drop.fromValue = NSValue(point: current)
            drop.toValue = NSValue(point: destination.origin)
            drop.damping = 26
            drop.stiffness = 300
            drop.duration = drop.settlingDuration
            snapshot.add(drop, forKey: "drop")
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.18
            snapshot.opacity = 0
            snapshot.add(fade, forKey: "fade")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = destination == nil ? 0.18 : 0.28
            blur.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }
}
