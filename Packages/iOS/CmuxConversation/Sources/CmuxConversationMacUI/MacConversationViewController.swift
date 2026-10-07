#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

/// Transcript table that routes trackpad horizontal swipes and clicks on
/// row accessories (badges, footers) back to the controller.
final class MacTranscriptTableView: NSTableView {
    weak var interaction: MacConversationViewController?

    override func scrollWheel(with event: NSEvent) {
        if interaction?.handleHorizontalScroll(event, in: self) == true { return }
        super.scrollWheel(with: event)
        // Mouse wheels scroll without live-scroll notifications.
        interaction?.userDidScroll()
    }

    override func mouseDown(with event: NSEvent) {
        if interaction?.handleClick(event, in: self) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        interaction?.contextMenu(for: event, in: self)
    }

    /// Bubble text takes clicks itself (selection, drag-out); a table only
    /// lets controls in its rows become first responder by default.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is MacBubbleTextView || super.validateProposedFirstResponder(responder, for: event)
    }

    // Up / Down move the selected message; Esc leaves the transcript.
    override func keyDown(with event: NSEvent) {
        guard let interaction, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 48: moveKeyFocus(event)
        case 126: interaction.moveMessageSelection(by: -1)
        case 125: interaction.moveMessageSelection(by: 1)
        case 53: interaction.cancelOperation(nil)
        case 51, 117: interaction.deleteSelectedMessage()
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { interaction?.transcriptDidBecomeFocused() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { interaction?.transcriptFocusMayHaveLeft() }
        return resigned
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
    let keyboard = MacConversationKeyboardState()
    let audioPlayer = ConversationAudioPlayer()
    lazy var audioComposer = MacAudioComposer(controller: self)
    private let initialSpinner = NSProgressIndicator()

    private(set) var rows: [MacConversationRow] = []
    private(set) var rowIndex: [String: Int] = [:]
    private var hasPositioned = false
    private var isPinnedToBottom = true
    private var arrivingRowIDs: Set<String> = []
    var effects = MacEffectsState()
    private var lastWidth: CGFloat = 0
    private var isLiveScrolling = false
    /// Sends whose bubble should fly from the composer once their row exists.
    private var pendingFlightRowIDs: [String] = []
    private var flightSource: (field: CGRect, text: CGRect)?
    private var isSubmitting = false
    /// 0...1 height of the typing row; animated so rows above glide.
    private var typingProgress: CGFloat = 0
    private var typingTarget: CGFloat = 0
    private var typingLink: CADisplayLink?
    private var typingAnimationStart: CFTimeInterval = 0
    private var typingAnimationFrom: CGFloat = 0
    /// The next configured typing row runs ChatKit's staged grow.
    private var typingShouldGrow = false
    #if DEBUG
    /// Lab `faketyping on|off`: a local typing indicator through the real row path.
    private var debugTyping = false
    /// Lab `trace`: per-event transcript geometry, to verify motion without video.
    private var traceLog: [String] = []
    private func trace(_ event: String) {
        guard traceLog.count < 4000 else { return }
        let bottomGap = tableView.bounds.height - (scrollView.contentView.bounds.maxY - scrollView.contentInsets.bottom)
        traceLog.append(String(format: "%.4f %@ progress=%.3f originY=%.1f tableH=%.1f bottomGap=%.1f", CACurrentMediaTime(), event, typingProgress, scrollView.contentView.bounds.origin.y, tableView.bounds.height, bottomGap))
    }
    #else
    private func trace(_ event: String) {}
    #endif

    // Reply / edit state.
    private(set) var replyTarget: ConversationMessage?
    weak var sendLaterPopover: NSPopover?
    var replyFocus: MacReplyFocusView?
    private(set) var editingMessageID: String?
    /// Rows animating to zero height before Delete removes them.
    private var collapsingRowIDs: Set<String> = []
    private let replyBanner = MacReplyBanner()

    // Swipe state.
    private var swipeAccumulatedX: CGFloat = 0
    private var swipeRowID: String?
    private var timestampsRevealed: CGFloat = 0
    /// Points outgoing bubbles travel at a full reveal (sized per swipe).
    private var timestampRevealDistance: CGFloat = 60
    /// Show Times (context menu or View menu): every time stays revealed.
    var showsTimes = false

    /// Messages' "Go Up" button (see the catch-up extension below).
    private let catchUpButton = NSButton()

    /// Shows and hides the details panel (the window's inspector).
    weak var detailsHost: (any MacConversationDetailsHost)?

    /// Toolbar (i), Conversation > Show Details (⌥⌘I): toggles the details panel.
    @objc public func toggleConversationDetails(_ sender: Any?) {
        guard let detailsHost else { return NSSound.beep() }
        detailsHost.toggleConversationDetails()
    }

    var isConversationDetailsShown: Bool { detailsHost?.isConversationDetailsShown ?? false }

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
        // The default (inset) style pads every row 16 pt on both sides.
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.interaction = self
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
        restoreDraft()
        installKeyboardSupport()
        installMentions()
        composer.linkPreview.fetch = { [weak store] url in await store?.fetchLinkPreview(for: url) }
        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        replyBanner.isHidden = true
        replyBanner.onClose = { [weak self] in self?.exitReplyOrEdit() }
        view.addSubview(replyBanner)


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
        NotificationCenter.default.addObserver(self, selector: #selector(textSizeDidChange), name: MacConversationTextSize.didChange, object: nil)
        installCatchUp()
        installTranslation()
        store.onChange = { [weak self] change in self?.storeDidChange(change) }
        installAudio()
        store.onScheduledActionFailed = { [weak self] in self?.presentScheduledActionFailure($0) }
        store.start()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        // A new window starts in the composer; on a conversation switch the
        // split controller decides (arrowing the list keeps focus there).
        if !(view.window?.firstResponder is NSView) { view.window?.makeFirstResponder(composer.textView) }
        // Messages opens a conversation at its newest message every time it
        // is selected; a place the reader scrolled to earlier is not kept.
        if hasPositioned {
            isPinnedToBottom = true
            scrollToBottom()
        }
    }


    public override func viewDidLayout() {
        super.viewDidLayout()
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
            programmatic {
                withoutAnimation {
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
                }
                reconfigureVisibleRows()
            }
            if isPinnedToBottom { scrollToBottom() } else { restore(anchor) }
        }
        composer.maximumFieldHeight = max(28, view.bounds.height * 0.40)
        // Row heights settle in layout passes; a pinned reader stays on the newest message.
        if hasPositioned, isPinnedToBottom, !isLiveScrolling, !isSubmitting { scrollToBottom() }
    }

    private func lastRowTrailingSpace() -> CGFloat {
        rows.last.map { lastRowTrailingSpace(of: $0) } ?? 0
    }

    private func lastRowTrailingSpace(of last: MacConversationRow) -> CGFloat {
        guard case let .message(model) = last else {
            // Measured: the typing bubble draws 3.5 pt past its row bottom.
            if case .typing = last { return -3.5 }
            return 0
        }
        let layout = layoutCache.layout(model, width: transcriptWidth)
        var bottom = layout.contentFrame.maxY
        if let bubble = layout.bubbleFrame { bottom = max(bottom, bubble.maxY + MacConversationTheme.tailDrop) }
        for frame in [layout.footerFrame, layout.editedFrame, layout.repliesFrame, layout.translationFrame].compactMap({ $0 }) {
            bottom = max(bottom, frame.maxY)
        }
        return max(0, layout.height - bottom)
    }

    private func updateInsets(followingBottom: Bool = true) {
        // While a send is in flight the collapsing composer must not shrink the
        // inset yet: the clip would clamp and drop the transcript before the
        // new row exists. composerDidSubmit applies it after the insert.
        guard !isSubmitting else { return }
        // The toolbar and the composer accessory arrive as safe-area insets.
        let top = view.safeAreaInsets.top
        // Measured: Messages keeps the lowest pixel of the newest row (a tail,
        // footer or image edge) 10.5 pt above the one-line composer pill, i.e.
        // 50 pt from the window bottom (the tail draws ~3.5 pt short of its
        // nominal drop); rows carry their own trailing space,
        // so the inset subtracts the last row's. It grows with the field.
        let composerGrowth = max(0, composer.fieldHeight - 32)
        let bottom = 50 - lastRowTrailingSpace() + composerGrowth + (replyBanner.isHidden ? 0 : 30) + layoutTranslationIndicator(aboveBottom: replyBanner.isHidden ? 0 : 30)
        let content = tableView.bounds.height
        let visible = scrollView.bounds.height - top - bottom
        // Short transcripts sit at the bottom, like Messages.
        let spacer = max(0, visible - content)
        let insets = NSEdgeInsets(top: top + spacer, left: 0, bottom: bottom, right: 0)
        let old = scrollView.contentInsets
        guard old.top != insets.top || old.bottom != insets.bottom else { return }
        programmatic {
            scrollView.contentInsets = insets
            scrollView.scrollerInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
        if followingBottom, isPinnedToBottom, hasPositioned { scrollToBottom() }
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

    /// Scrolls the transcript makes itself; any other bounds change is the
    /// reader's (wheel, keyboard, scroller, gesture) and updates the pin.
    private var programmaticScrollDepth = 0
    private var programmaticScrollAnimations = 0

    private func programmatic(_ body: () -> Void) {
        programmaticScrollDepth += 1
        body()
        programmaticScrollDepth -= 1
    }

    private func animateScroll(to target: NSPoint, duration: TimeInterval, timing: CAMediaTimingFunction? = nil) {
        programmaticScrollAnimations += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            if let timing { context.timingFunction = timing }
            context.allowsImplicitAnimation = true
            scrollView.contentView.animator().setBoundsOrigin(target)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.programmaticScrollAnimations -= 1 }
        })
    }

    func scrollToBottom(animated: Bool = false) {
        let target = NSPoint(x: 0, y: maxOffset)
        programmatic {
            if animated {
                animateScroll(to: target, duration: 0.3)
            } else {
                scrollView.contentView.scroll(to: target)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    @objc private func liveScrollStarted() { isLiveScrolling = true }

    func userDidScroll() {
        if !isLiveScrolling { isPinnedToBottom = isNearBottom() }
    }

    @objc private func liveScrollEnded() {
        isLiveScrolling = false
        isPinnedToBottom = isNearBottom()
    }

    @objc private func boundsDidChange() {
        let origin = scrollView.contentView.bounds.origin.y
        let readerScrolled = programmaticScrollDepth == 0 && programmaticScrollAnimations == 0
        if NSEvent.pressedMouseButtons != 0 || isLiveScrolling || readerScrolled {
            isPinnedToBottom = isNearBottom()
        }
        if origin + scrollView.contentInsets.top < scrollView.contentSize.height * 1.5 {
            store.loadOlder()
        } else if origin + scrollView.contentInsets.top > scrollView.contentSize.height * 3 {
            store.olderNoLongerWanted()
        }
        // Reading follows viewing (the window marks the store viewed), not
        // scroll position: Messages reads the whole conversation on open.
        updateCatchUp()
    }

    private struct Anchor {
        var rowID: String
        var offset: CGFloat
    }

    private func bubbleTop(_ index: Int) -> CGFloat? {
        guard index < rows.count, case let .message(model) = rows[index] else { return nil }
        let rect = tableView.rect(ofRow: index)
        return rect.minY + topSpacing(at: index, model) + layoutCache.layout(model, width: transcriptWidth).contentFrame.minY
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
        programmatic {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(-scrollView.contentInsets.top, y - anchor.offset), maxOffset)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: Store changes

    /// Whose "has notifications silenced" row the transcript shows.
    private var shownSilencedID: String?

    private func storeDidChange(_ change: ConversationStoreChange) {
        if store.hasLoadedNewest, !initialSpinner.isHidden {
            initialSpinner.stopAnimation(nil)
            initialSpinner.isHidden = true
        }
        if let info = store.info { onInfoChange?(info, store.meID, store.connection == .connected) }
        if case .connection = change { return }
        if case .readState = change { updateCatchUp(); return }
        // List state leaves the transcript alone, except the recipient's
        // Focus, which adds or removes the "has notifications silenced" row.
        if case .listState = change, store.info?.silencedRecipient?.id == shownSilencedID { return }
        shownSilencedID = store.info?.silencedRecipient?.id
        if case .draft = change {
            restoreDraft()
            return
        }
        defer { updateCatchUp() }

        var newRows = MacConversationRowBuilder.rows(store: store)
        #if DEBUG
        if debugTyping, !newRows.contains(where: { if case .typing = $0 { return true } else { return false } }),
           let someone = store.info?.participants.first(where: { $0.id != store.meID }) {
            newRows.insert(.typing(participantIDs: [someone.id]), at: MacConversationRowBuilder.typingSlot(in: newRows))
        }
        #endif
        let oldRows = rows
        let oldIDs = Set(rowIndex.keys)
        let wasAtBottom = isPinnedToBottom || isNearBottom()
        let anchor = captureAnchor()
        var sentByMe = false
        if case let .live(inserted, mine) = change { sentByMe = mine && !inserted.isEmpty }
        announceArrivals(newRows.filter { !oldIDs.contains($0.id) }, change: change)
        // A typing indicator that stops without a message collapses first, so
        // the rows above glide down instead of jumping.
        // The indicator sits at the end of the transcript, above any Send Later rows.
        let isTyping: (MacConversationRow) -> Bool = { if case .typing = $0 { return true } else { return false } }
        let oldTypingIndex = oldRows.firstIndex(where: isTyping)
        let typingLeft = oldTypingIndex != nil
        let typingNow = newRows.contains(where: isTyping)
        if case .live = change {
            let arrivals = newRows.compactMap { row -> String? in
                // A bubble effect is the row's entrance; other arrivals fade in.
                guard !oldIDs.contains(row.id), case let .message(model) = row, !model.isOutgoing, !queueArrivalEffect(model) else { return nil }
                return model.rowID
            }
            // The message that replaces a typing indicator takes its place at
            // full opacity, so the hand-off never passes through an empty frame.
            let handoff = typingLeft && !typingNow ? arrivals.last : nil
            for id in arrivals where id != handoff { arrivingRowIDs.insert(id) }
        }
        let slot = MacConversationRowBuilder.typingSlot(in: newRows)
        let lastIsNew = slot > 0 && !oldIDs.contains(newRows[slot - 1].id)
        if typingLeft, !typingNow, !lastIsNew, hasPositioned, typingProgress > 0, let oldTypingIndex {
            newRows.insert(oldRows[oldTypingIndex], at: slot)
            animateTyping(to: 0)
        } else if typingNow, !typingLeft {
            typingProgress = 0
            typingShouldGrow = true
            animateTyping(to: 1)
        } else if typingNow {
            animateTyping(to: 1)
        }

        defer { if threadFocus != nil { reloadThread(animated: false) } }
        defer { playQueuedEffects() }
        trace("change.before \(change)")
        programmatic {
            apply(newRows, from: oldRows)
            updateInsets()
        }
        defer { trace("change.after \(change)") }

        if !hasPositioned {
            if store.hasLoadedNewest, !rows.isEmpty {
                hasPositioned = true
                view.layoutSubtreeIfNeeded()
                scrollToBottom()
            }
            return
        }
        if isSubmitting {
            // composerDidSubmit runs the flight once send() returns the row id.
            return
        } else if sentByMe {
            isPinnedToBottom = true
            scrollToBottom(animated: true)
        } else if case .live = change, wasAtBottom {
            scrollToBottom(animated: true)
        } else if case .typing = change, isPinnedToBottom {
            // The typing row's own height animation keeps the bottom pinned.
            scrollToBottom()
        } else if isPinnedToBottom, change != .prepended {
            // Status and rebase changes keep a pinned reader at the bottom.
            scrollToBottom()
        } else {
            restore(anchor)
        }
    }

    /// Applies a new row list with minimal table work: removals, insertions,
    /// and in-place reconfiguration keyed by stable row identity. A pending
    /// send keeps its row (and view) when the server acknowledges it.
    private func apply(_ newRows: [MacConversationRow], from oldRows: [MacConversationRow]) {
        rows = newRows
        rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        guard !oldRows.isEmpty, tableView.numberOfRows == oldRows.count else {
            tableView.reloadData()
            tableView.layoutSubtreeIfNeeded()
            return
        }
        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        var removals = IndexSet()
        var insertions = IndexSet()
        for step in newIDs.difference(from: oldIDs) {
            switch step {
            case let .remove(offset, _, _): removals.insert(offset)
            case let .insert(offset, _, _): insertions.insert(offset)
            }
        }
        let newIDSet = Set(newIDs)
        for index in removals {
            guard case let .message(model) = oldRows[index], newIDSet.contains("unsent:\(model.rowID)"),
                  let bubble = rowView(at: index) else { continue }
            dissolve(bubble)
        }
        var oldByID: [String: (index: Int, row: MacConversationRow)] = [:]
        for (index, row) in oldRows.enumerated() { oldByID[row.id] = (index, row) }
        var changed = IndexSet()
        for (index, row) in newRows.enumerated() where !insertions.contains(index) {
            guard let old = oldByID[row.id] else { continue }
            let previousOld = old.index > 0 ? oldRows[old.index - 1].isMessage : false
            let previousNew = index > 0 ? newRows[index - 1].isMessage : false
            if old.row != row || previousOld != previousNew { changed.insert(index) }
        }
        withoutAnimation {
            tableView.beginUpdates()
            if !removals.isEmpty { tableView.removeRows(at: removals, withAnimation: []) }
            if !insertions.isEmpty { tableView.insertRows(at: insertions, withAnimation: []) }
            tableView.endUpdates()
            if !changed.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: changed) }
        }
        for index in changed {
            guard let view = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) else { continue }
            let oldModel = oldByID[newRows[index].id].flatMap { entry -> MacMessageRowModel? in
                if case let .message(model) = entry.row { return model } else { return nil }
            }
            let oldMinX = (view as? MacMessageContainerView)?.row.contentFrame.minX
            configure(view, row: index)
            if let oldModel, let oldMinX, let newModel = messageModel(at: index),
               (oldModel.footer == .notDelivered) != (newModel.footer == .notDelivered) {
                (view as? MacMessageContainerView)?.row.animateFailedChange(fromContentMinX: oldMinX, failed: newModel.footer == .notDelivered)
            }
        }
        tableView.layoutSubtreeIfNeeded()
    }

    /// Undo Send: Messages' pop (the bubble swells, then breaks into debris)
    /// over a snapshot while the row turns into its notice underneath.
    /// Reduce Motion fades it instead.
    private func dissolve(_ rowView: MacMessageRowView) {
        let frame = rowView.contentFrame
        guard frame.width > 0, frame.height > 0,
              let rep = rowView.bitmapImageRepForCachingDisplay(in: frame) else { return }
        rowView.cacheDisplay(in: frame, to: rep)
        guard let image = rep.cgImage else { return }
        let inTable = rowView.convert(frame, to: tableView)
        let outset = ConversationPopEffect.clipOutset
        let overlay = PopOverlayView(frame: inTable.insetBy(dx: -outset, dy: -outset))
        tableView.addSubview(overlay)
        guard let host = overlay.layer else { overlay.removeFromSuperview(); return }
        ConversationPopEffect.play(
            image: image,
            frame: overlay.convert(inTable, from: tableView),
            in: host,
            contentsScale: view.window?.backingScaleFactor ?? 2,
            yUp: true,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) {
            overlay.removeFromSuperview()
        }
    }

    /// Delete for me: the rows fade and collapse (neighbors close the gap on
    /// the same curve), then leave the store.
    func deleteLocally(_ rowIDs: Set<String>) {
        let indexes = IndexSet(rowIDs.compactMap { rowIndex[$0] })
        guard !indexes.isEmpty else { return store.deleteLocally(rowIDs: rowIDs) }
        collapsingRowIDs.formUnion(rowIDs)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            for index in indexes {
                tableView.view(atColumn: 0, row: index, makeIfNecessary: false)?.animator().alphaValue = 0
            }
            programmatic { tableView.noteHeightOfRows(withIndexesChanged: indexes) }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.deleteLocally(rowIDs: rowIDs)
                self.collapsingRowIDs.subtract(rowIDs)
                for index in indexes where index < self.tableView.numberOfRows {
                    self.tableView.view(atColumn: 0, row: index, makeIfNecessary: false)?.alphaValue = 1
                }
            }
        }
    }

    /// Clicking "(!) Not Unsent": Try Again while the two-minute window is
    /// open, otherwise just the explanation (ChatKit's two alerts).
    func presentNotUnsent(messageID: String) {
        guard let message = store.message(id: messageID), message.unsendFailed else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "conversation.notUnsent.title", defaultValue: "Message Not Unsent", bundle: .module)
        let canRetry = store.canRetryUnsend(message)
        if canRetry {
            alert.informativeText = String(localized: "conversation.notUnsent.retryBody", defaultValue: "The original message will still be visible.", bundle: .module)
            alert.addButton(withTitle: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module))
            alert.addButton(withTitle: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module))
        } else {
            alert.informativeText = String(localized: "conversation.notUnsent.expiredBody", defaultValue: "Your message was not unsent. The original message will still be visible.", bundle: .module)
            alert.addButton(withTitle: String(localized: "conversation.notUnsent.ok", defaultValue: "OK", bundle: .module))
        }
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard canRetry, response == .alertFirstButtonReturn else { return }
            self?.store.retryUnsend(messageID: messageID)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Edit > Undo (Cmd-Z) with nothing to undo in the composer offers to
    /// take back my last message, as Messages does: "Undo Send?" within two
    /// minutes, "Undo Send Not Available" (edit only) within fifteen.
    @objc func undo(_ sender: Any?) {
        if let manager = view.window?.undoManager, manager.canUndo {
            manager.undo()
            return
        }
        guard let message = store.lastSentByMe else { return }
        presentUndoSend(for: message)
    }

    func presentUndoSend(for message: ConversationMessage) {
        guard let (alert, actions) = makeUndoSendAlert(for: message) else { return }
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < actions.count else { return }
            actions[index]()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// The alert and one action per button before Cancel; nil when the
    /// message can be neither unsent nor edited.
    func makeUndoSendAlert(for message: ConversationMessage) -> (NSAlert, [() -> Void])? {
        let canUnsend = store.canUnsend(message)
        let canEdit = store.canEdit(message)
        guard canUnsend || canEdit else { return nil }
        let alert = NSAlert()
        if canUnsend {
            alert.messageText = String(localized: "conversation.undoSend.title", defaultValue: "Undo Send?", bundle: .module)
            alert.informativeText = String(localized: "conversation.undoSend.body", defaultValue: "You can unsend messages for up to 2 minutes.", bundle: .module)
        } else {
            alert.messageText = String(localized: "conversation.undoSend.expiredTitle", defaultValue: "Undo Send Not Available", bundle: .module)
            alert.informativeText = String(localized: "conversation.undoSend.expiredBody", defaultValue: "This message was sent more than 2 minutes ago. You can edit it for up to 15 minutes.", bundle: .module)
        }
        // Buttons as in Messages: Edit Message (when editable), Undo Send
        // (inside two minutes), Cancel.
        var actions: [() -> Void] = []
        let messageID = message.id
        if canEdit {
            alert.addButton(withTitle: String(localized: "conversation.undoSend.edit", defaultValue: "Edit Message", bundle: .module))
            actions.append { [weak self] in
                guard let self, let current = self.store.message(id: messageID), self.store.canEdit(current) else { return }
                self.enterEdit(current)
            }
        }
        if canUnsend {
            alert.addButton(withTitle: String(localized: "conversation.undoSend.undo", defaultValue: "Undo Send", bundle: .module))
            actions.append { [weak self] in self?.store.unsend(messageID: messageID) }
        }
        alert.addButton(withTitle: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module))
        return (alert, actions)
    }

    func confirmDelete(_ model: MacMessageRowModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "conversation.delete.confirmTitle", defaultValue: "Are you sure you want to delete this message?", bundle: .module)
        alert.informativeText = String(localized: "conversation.delete.confirmBody", defaultValue: "This message will be deleted from this device.", bundle: .module)
        alert.addButton(withTitle: String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module)).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module))
        let rowID = model.rowID
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deleteLocally([rowID])
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        body()
        NSAnimationContext.endGrouping()
    }

    /// View > Make Text Bigger / Smaller: every bubble re-measures at the new
    /// size, keeping the newest message (or the reader's place) in view.
    @objc func textSizeDidChange() {
        let anchor = captureAnchor()
        layoutCache.invalidate()
        programmatic {
            withoutAnimation {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            }
            reconfigureVisibleRows()
        }
        updateInsets()
        if isPinnedToBottom { scrollToBottom() } else { restore(anchor) }
    }

    /// Re-lays out every on-screen row at the current width (live resize).
    private func reconfigureVisibleRows() {
        tableView.enumerateAvailableRowViews { rowView, index in
            guard index < rows.count, let view = rowView.view(atColumn: 0) as? NSView else { return }
            configure(view, row: index)
        }
    }

    // MARK: Typing height

    private func animateTyping(to target: CGFloat) {
        guard typingTarget != target || (typingLink == nil && typingProgress != target) else { return }
        typingTarget = target
        typingAnimationFrom = typingProgress
        typingAnimationStart = CACurrentMediaTime()
        if typingLink == nil {
            let link = view.displayLink(target: self, selector: #selector(typingTick))
            link.add(to: .main, forMode: .common)
            typingLink = link
        }
    }

    @objc private func typingTick() {
        // The indicator grows and collapses over 0.3 s, ease-out.
        let t = min(1, (CACurrentMediaTime() - typingAnimationStart) / 0.3)
        let eased = 1 - pow(1 - t, 3)
        typingProgress = typingAnimationFrom + (typingTarget - typingAnimationFrom) * eased
        if let index = rows.lastIndex(where: { if case .typing = $0 { return true } else { return false } }) {
            programmatic { withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index)) } }
            if let typingView = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacTypingRowView {
                typingView.progress = typingProgress
            }
            updateInsets()
            if isPinnedToBottom { scrollToBottom() }
            trace("typing.tick")
        }
        guard t >= 1 else { return }
        typingLink?.invalidate()
        typingLink = nil
        if typingTarget == 0, store.typingParticipantIDs.isEmpty, !isDebugTyping,
           rows.contains(where: { if case .typing = $0 { return true } else { return false } }) {
            storeDidChange(.typing)
        }
    }

    private var isDebugTyping: Bool {
        #if DEBUG
        return debugTyping
        #else
        return false
        #endif
    }

    // MARK: Send flight

    /// Messages' send: the bubble starts as the composer field (its position
    /// and width) and springs into place while the transcript scrolls up.
    /// Messages' send flight drawn above everything: a rounded body that
    /// resizes from the composer field to the bubble (no stretched tail or
    /// text) and the text gliding unscaled; the real row shows on landing.
    private func flyOverComposer(_ row: MacMessageRowView, field: CGRect, text: CGRect, scrollDelta: CGFloat) -> Bool {
        guard let host = view.window?.contentView, let layout = row.rowLayout, let model = row.model,
              let bubble = layout.bubbleFrame, let textFrame = layout.textFrame,
              layout.imageFrames.isEmpty, layout.emojiFrame == nil,
              let rep = row.textLabel.bitmapImageRepForCachingDisplay(in: row.textLabel.bounds) else { return false }
        row.textLabel.cacheDisplay(in: row.textLabel.bounds, to: rep)
        func landing(_ rect: CGRect) -> CGRect {
            var r = host.convert(row.convert(rect, to: nil), from: nil)
            // The transcript scrolls up by the delta while the bubble flies.
            r.origin.y += host.isFlipped ? -scrollDelta : scrollDelta
            return r
        }
        let toBody = landing(bubble)
        let toText = landing(textFrame)
        let fromBody = host.convert(field, from: nil)
        let fromTextOrigin = host.convert(text, from: nil).origin
        let overlay = MacFlightOverlayView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
        let color = resolved(model.isOutgoing ? MacConversationTheme.outgoingBubble : MacConversationTheme.incomingBubble, in: row)
        row.alphaValue = 0
        // Trailing edge pinned at the bubble's from the first frame (measured
        // on iOS Messages; ChatKit's throw is shared with the Mac).
        var start = fromBody
        start.size.width = max(toBody.width, toBody.maxX - start.minX)
        overlay.fly(color: color, text: rep.cgImage, textSize: textFrame.size, fromBody: start, toBody: toBody,
                    fromText: CGRect(origin: fromTextOrigin, size: textFrame.size), toText: toText,
                    tail: model.showsTail) { [weak row, weak overlay] in
            row?.alphaValue = 1
            overlay?.removeFromSuperview()
        }
        return true
    }

    private func runPendingFlights() {
        let ids = pendingFlightRowIDs
        pendingFlightRowIDs = []
        let source = flightSource
        flightSource = nil
        view.layoutSubtreeIfNeeded()
        let start = scrollView.contentView.bounds.origin.y
        let end = maxOffset
        for id in ids {
            guard let index = rowIndex[id], let row = rowView(at: index), let source else { continue }
            // Text sends fly in an overlay above the composer, so the first
            // frame is never clipped by it; images and emoji fly in place.
            if !flyOverComposer(row, field: source.field, text: source.text, scrollDelta: end - start) {
                row.flyIn(fromField: row.convert(source.field, from: nil), text: row.convert(source.text, from: nil))
            }
        }
        trace(String(format: "flight scroll %.1f -> %.1f", start, end))
        if abs(end - start) > 0.5 {
            programmatic {
                animateScroll(to: NSPoint(x: 0, y: end), duration: 0.32, timing: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
            }
        } else {
            scrollToBottom()
        }
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case let .message(model):
            // A row being deleted collapses to nothing before it leaves.
            if collapsingRowIDs.contains(model.rowID) { return 0.01 }
            let layout = layoutCache.layout(model, width: transcriptWidth)
            return layout.height + topSpacing(at: row, model)
        case .timestamp, .notice: return MacTimestampRowView.height
        case .sendLaterHeader: return MacSendLaterHeaderRowView.height
        case let .systemEvent(_, text): return MacSystemEventRowView.height(text, width: transcriptWidth)
        case let .unavailability(_, messageID): return MacUnavailabilityRowView.height(showsNotifyAnyway: messageID != nil)
        case .loadingOlder: return MacSpinnerRowView.height
        case .conversationStart: return MacConversationStartRowView.height
        case .typing: return max(0.01, MacTypingRowView.height * typingProgress)
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier: String
        switch rows[row] {
        case .message: identifier = "m"
        case .timestamp, .notice: identifier = "t"
        case .sendLaterHeader: identifier = "sl"
        case .systemEvent: identifier = "e"
        case .unavailability: identifier = "u"
        case .loadingOlder: identifier = "l"
        case .conversationStart: identifier = "s"
        case .typing: identifier = "y"
        }
        let view: NSView = tableView.makeView(withIdentifier: .init(identifier), owner: nil) ?? {
            switch rows[row] {
            case .message: return MacMessageContainerView()
            case .timestamp, .notice: return MacTimestampRowView()
            case .sendLaterHeader: return MacSendLaterHeaderRowView()
            case .systemEvent: return MacSystemEventRowView()
            case .unavailability: return MacUnavailabilityRowView()
            case .loadingOlder: return MacSpinnerRowView()
            case .conversationStart: return MacConversationStartRowView()
            case .typing: return MacTypingRowView()
            }
        }()
        view.identifier = .init(identifier)
        configure(view, row: row)
        if let container = view as? MacMessageContainerView, case let .message(model) = rows[row] {
            animateIfNeeded(container, model: model)
        }
        return view
    }

    /// Space above a message row; it changes when the row above it changes
    /// kind (a page replacing a date header), so anchors must include it.
    private func topSpacing(at row: Int, _ model: MacMessageRowModel) -> CGFloat {
        row > 0 && rows[row - 1].isMessage
            ? (model.isFirstInRun ? MacConversationTheme.runSpacing : MacConversationTheme.groupedSpacing) : 4
    }

    private func configure(_ view: NSView, row: Int) {
        switch rows[row] {
        case let .message(model):
            guard let view = view as? MacMessageContainerView else { return }
            view.topSpacing = topSpacing(at: row, model)
            view.row.audioDelegate = self
            view.row.configure(model, layout: layoutCache.layout(model, width: transcriptWidth), text: layoutCache.text(model))
            view.timestampRevealDistance = timestampRevealDistance
            applyMessageSelection(to: view.row)
            applyFindHighlight(to: view.row)
            configureAccessibility(view.row, model: model)
            view.timestampReveal = timestampsRevealed
        case let .timestamp(_, date):
            (view as? MacTimestampRowView)?.configure(date: date)
        case let .notice(notice):
            (view as? MacTimestampRowView)?.configure(notice: notice)
        case let .sendLaterHeader(rowID, date, failed):
            guard let header = view as? MacSendLaterHeaderRowView else { return }
            header.configure(date: date, failed: failed)
            header.menuProvider = { [weak self, weak header] in
                guard let self, let header else { return NSMenu() }
                return self.sendLaterMenu(rowID: rowID, anchor: header)
            }
        case let .systemEvent(_, text):
            (view as? MacSystemEventRowView)?.configure(text)
        case let .unavailability(name, messageID):
            guard let view = view as? MacUnavailabilityRowView else { return }
            view.configure(name: name, showsNotifyAnyway: messageID != nil)
            view.onNotifyAnyway = { [weak self] in
                guard let messageID else { return }
                self?.store.notifyAnyway(messageID: messageID)
            }
        case .loadingOlder:
            (view as? MacSpinnerRowView)?.spinner.startAnimation(nil)
        case .conversationStart:
            (view as? MacConversationStartRowView)?.configure(title: serviceTitle, subtitle: String(localized: "conversation.start.encrypted", defaultValue: "Encrypted", bundle: .module))
        case let .typing(ids):
            guard let view = view as? MacTypingRowView else { return }
            view.showsAvatar = store.info?.kind == .group
            view.avatar.initials = ids.first.flatMap { store.info?.participant($0)?.initials } ?? ""
            view.avatar.colorHex = ids.first.flatMap { store.info?.participant($0)?.colorHex }
            view.progress = typingProgress
            if typingShouldGrow {
                typingShouldGrow = false
                view.grow()
            }
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// Arrivals grow from their tail corner (the bubble's bottom leading edge).
    private func animateIfNeeded(_ view: MacMessageContainerView, model: MacMessageRowModel) {
        guard arrivingRowIDs.remove(model.rowID) != nil else { return }
        view.row.growIn()
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
        // A message being edited is not a draft.
        if editingMessageID == nil { store.setDraft(composer.text) }
    }

    /// Puts a saved draft back in an empty composer (after relaunch, or once
    /// an edit ends).
    func restoreDraft() {
        guard editingMessageID == nil, composer.text.isEmpty, !store.draft.isEmpty else { return }
        composer.text = store.draft
    }

    func composerDidChangeHeight(_ composer: MacComposerView) {
        onComposerHeightChange?()
        view.layoutSubtreeIfNeeded()
        updateInsets()
    }

    func composerDidSubmit(_ composer: MacComposerView) {
        tapbackPopover?.close()
        if let messageID = editingMessageID {
            store.edit(messageID: messageID, text: composer.text, textRuns: composer.textRuns)
            // Ending the edit clears the composer and brings the draft back.
            exitReplyOrEdit()
            return
        }
        if scheduleIfSendLater(composer) {
            if replyTarget != nil, threadFocus == nil { exitReplyOrEdit(sent: true) }
            return
        }
        let images = composer.attachments.map { attachment in
            (data: attachment.data, width: Int(attachment.image.size.width), height: Int(attachment.image.size.height), mimeType: attachment.mimeType)
        }
        let replyTo = replyTarget?.id
        let text = composer.text
        let mentions = composer.mentions
        let textRuns = composer.textRuns
        let linkPreview = composer.linkPreview.sendablePreview
        // The bubble flies from where the draft sits, captured before the
        // composer collapses; the collapse and insert land in one scroll.
        flightSource = (
            field: composer.field.convert(composer.field.bounds, to: nil),
            text: composer.scrollView.convert(composer.scrollView.bounds, to: nil)
        )
        trace("submit.begin")
        isSubmitting = true
        composer.clearAfterSend()
        trace("submit.cleared")
        let effect = effects.pendingSendEffect
        let rowID = store.send(text: text, images: images, replyToID: replyTo, mentions: mentions, textRuns: textRuns, linkPreview: linkPreview, effect: effect)
        isSubmitting = false
        if let rowID { registerUndoSend(rowID: rowID) }
        // The flight's scroll animates to the new bottom.
        updateInsets(followingBottom: false)
        if let rowID, rowIndex[rowID] != nil {
            // A bubble effect replaces the flight: the bubble makes its entrance in place.
            if effect?.kind != .bubble { pendingFlightRowIDs.append(rowID) }
            isPinnedToBottom = true
            runPendingFlights()
            if effect != nil { playEffect(rowID: rowID, explicit: false) }
        } else {
            flightSource = nil
            updateInsets()
        }
        // In a thread the focus stays up and the new reply joins it.
        if replyTarget != nil, threadFocus == nil { exitReplyOrEdit(sent: true) }
    }

    func composerDidTapApps(_ composer: MacComposerView) {
        let menu = NSMenu()
        let photos = NSMenuItem(title: String(localized: "conversation.apps.photos", defaultValue: "Photos", bundle: .module), action: #selector(choosePhotos), keyEquivalent: "")
        photos.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)
        photos.target = self
        menu.addItem(photos)
        menu.addItem(effectsMenuItem())
        menu.addItem(pollsAppsMenuItem())
        menu.addItem(sendLaterAppsMenuItem())
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: composer.appsButton.bounds.height + 4), in: composer.appsButton)
    }

    @objc private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { if let attachment = MacComposerAttachment.fromFile(url) { self?.composer.addAttachment(attachment) } }
        }
    }

    // MARK: Reply / edit

    func enterReply(_ message: ConversationMessage) {
        tapbackPopover?.close()
        editingMessageID = nil
        replyTarget = message
        composer.isReplyMode = true
        composer.isEditMode = false
        replyBanner.isHidden = true
        updateInsets()
        showReplyFocus(for: message)
        view.window?.makeFirstResponder(composer.textView)
    }

    /// Messages' reply focus: the transcript darkens and blurs, and the
    /// whole thread (root and replies) is laid out as ordinary rows at the
    /// transcript's own margins, bottom-anchored above the composer. It stays
    /// up after a send, so further replies go to the same thread.
    private func showReplyFocus(for message: ConversationMessage) {
        threadFocus?.removeFromSuperview()
        let rootID = message.replyToID ?? message.id
        threadRootID = rootID
        replyTarget = store.message(id: rootID) ?? message
        let focus = MacThreadFocusView(frame: scrollView.frame)
        focus.autoresizingMask = [.width, .height]
        focus.onDismiss = { [weak self] in self?.exitReplyOrEdit() }
        view.addSubview(focus, positioned: .above, relativeTo: scrollView)
        threadFocus = focus
        reloadThread(animated: true)
    }

    private var threadFocus: MacThreadFocusView?
    private var threadRootID: String?

    private func reloadThread(animated: Bool) {
        guard let focus = threadFocus, let rootID = threadRootID else { return }
        // Messages blurs the transcript in place and re-renders the thread's
        // rows crisp as plain thread rows (no quote pill, no reply-count link,
        // names and tapbacks kept), each bubble keeping its on-screen position;
        // a root scrolled off the top pins under the bar.
        let width = transcriptWidth
        let threadRows = MacConversationRowBuilder.threadRows(rootID: rootID, store: store)
        var transcriptIndex: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if case let .message(model) = row { transcriptIndex[model.rowID] = index }
        }
        if let lastID = threadRows.reversed().compactMap({ row -> String? in
            if case let .message(model) = row { return model.rowID } else { return nil }
        }).first, let last = transcriptIndex[lastID] {
            let rect = tableView.rect(ofRow: last)
            let bottomLimit = scrollView.contentView.bounds.origin.y + scrollView.bounds.height - scrollView.contentInsets.bottom
            if rect.maxY > bottomLimit {
                programmatic {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, rect.maxY - (scrollView.bounds.height - scrollView.contentInsets.bottom))))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
        view.layoutSubtreeIfNeeded()
        var placed: [(NSView, CGRect)] = []
        var pinnedTop = view.safeAreaInsets.top + 8
        var pendingTimestamp: MacTimestampRowView?
        for row in threadRows {
            switch row {
            case let .timestamp(_, date):
                let view = MacTimestampRowView()
                view.configure(date: date)
                pendingTimestamp = view
            case let .message(model):
                guard let index = transcriptIndex[model.rowID], case let .message(transcriptModel) = rows[index] else { continue }
                let container = MacMessageContainerView()
                let layout = layoutCache.layout(model, width: width)
                container.row.audioDelegate = self
                container.row.configure(model, layout: layout, text: layoutCache.text(model))
                // Keep the bubble where the transcript draws it: offset by the
                // difference between the transcript row's content position and
                // the thread-mode layout's.
                let transcriptLayout = layoutCache.layout(transcriptModel, width: width)
                let rowRect = tableView.rect(ofRow: index)
                let spacing = topSpacing(at: index, transcriptModel)
                var y = focus.convert(rowRect, from: tableView).minY + spacing + transcriptLayout.contentFrame.minY - layout.contentFrame.minY
                if let timestamp = pendingTimestamp {
                    // Over the transcript's own timestamp row when it has one,
                    // so the two coincide instead of doubling up (a reply's
                    // row is taller than its thread row by the quote pill).
                    var tsY = y - 10 - MacTimestampRowView.height
                    if index > 0, case .timestamp = rows[index - 1] {
                        let tsRow = focus.convert(tableView.rect(ofRow: index - 1), from: tableView)
                        tsY = tsRow.midY - MacTimestampRowView.height / 2
                    }
                    let tsFrame = CGRect(x: 0, y: max(pinnedTop, tsY), width: width, height: MacTimestampRowView.height)
                    placed.append((timestamp, tsFrame))
                    pinnedTop = tsFrame.maxY
                    pendingTimestamp = nil
                }
                y = max(y, pinnedTop)
                placed.append((container, CGRect(x: 0, y: y, width: width, height: layout.height)))
                pinnedTop = y + layout.height
            default:
                continue
            }
        }
        focus.show(placed, animated: animated)
    }

    private func dismissReplyFocus(sent: Bool, then completion: (@MainActor () -> Void)? = nil) {
        if let focus = threadFocus {
            threadFocus = nil
            threadRootID = nil
            focus.dismiss()
        }
        guard let focus = replyFocus else { return }
        replyFocus = nil
        var destination: CGRect?
        if !sent, let message = focus.messageID,
           let index = rows.firstIndex(where: { if case let .message(model) = $0 { return model.message.id == message } else { return false } }),
           let row = rowView(at: index) {
            destination = row.convert(row.bounds, to: focus)
        }
        focus.dismiss(returningTo: destination, then: completion)
    }

    func enterEdit(_ message: ConversationMessage) {
        replyTarget = nil
        editingMessageID = message.id
        composer.isReplyMode = false
        composer.isEditMode = true
        composer.setText(message.text, runs: message.textRuns)
        replyBanner.configure(title: String(localized: "conversation.menu.edit", defaultValue: "Edit", bundle: .module), text: message.text)
        replyBanner.isHidden = false
        updateInsets()
        view.window?.makeFirstResponder(composer.textView)
    }

    func exitReplyOrEdit(sent: Bool = false) {
        dismissReplyFocus(sent: sent)
        if editingMessageID != nil { composer.clearAfterSend() }
        replyTarget = nil
        let wasEditing = editingMessageID != nil
        editingMessageID = nil
        composer.isReplyMode = false
        composer.isEditMode = false
        replyBanner.isHidden = true
        if wasEditing { restoreDraft() }
        updateInsets()
    }

    public override func cancelOperation(_ sender: Any?) {
        if reactionPicker != nil { dismissReactionFocus(); return }
        if cancelMessageSelection() { return }
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
        if event.clickCount == 1, let (index, _) = row(at: event, in: table), index < rows.count,
           case let .notice(notice) = rows[index], notice.failure != nil {
            presentNotUnsent(messageID: notice.messageID)
            return true
        }
        if event.clickCount == 2, let (index, point) = row(at: event, in: table), let rowView = rowView(at: index),
           rowView.quickLookPhoto(at: rowView.convert(point, from: table)) {
            return true
        }
        if event.clickCount == 1 { updateMessageSelection(forClick: event, in: table) }
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
        if !rowView.translationLabel.isHidden, rowView.translationLabel.frame.insetBy(dx: 0, dy: -3).contains(local) {
            store.translations.toggleOriginal(rowID: model.rowID)
            return true
        }
        if handlePollClick(model, rowView: rowView, local: local) { return true }
        // Messages opens the thread focus from the replies link and from a
        // reply's quote.
        if !rowView.repliesLabel.isHidden, rowView.repliesLabel.frame.contains(local) {
            enterReply(model.message)
            return true
        }
        if let quote = rowView.rowLayout?.quoteFrame, quote.contains(local), model.message.replyToID != nil {
            enterReply(model.message)
            return true
        }
        if let text = rowView.rowLayout?.textFrame, text.contains(local),
           let participantID: String = textAttribute(.macConversationMention, in: model, at: CGPoint(x: local.x - text.minX, y: local.y - text.minY), width: text.width) {
            showMentionCard(participantID: participantID, at: local, in: rowView)
            return true
        }
        if let card = rowView.rowLayout?.linkCardFrame, card.contains(local), let preview = model.message.linkPreview {
            if isHold(after: event) {
                if model.message.seq != nil { showReactionFocus(model, in: rowView) }
                return true
            }
            switch preview.state {
            case .tapToLoad: store.loadLinkPreview(messageID: model.message.id)
            case .loaded, .loading: NSWorkspace.shared.open(preview.url)
            }
            return true
        }
        if let text = rowView.rowLayout?.textFrame, text.contains(local),
           let url = link(in: model, at: CGPoint(x: local.x - text.minX, y: local.y - text.minY), width: text.width) {
            NSWorkspace.shared.open(url)
            return true
        }
        if rowView.contentFrame.contains(local), model.message.seq != nil, isHold(after: event) {
            showReactionFocus(model, in: rowView)
            return true
        }
        return false
    }

    /// Press-and-hold on a bubble: tracks the mouse for Messages' long-press
    /// interval; a release or drag first means an ordinary click.
    private func isHold(after event: NSEvent) -> Bool {
        guard let window = view.window else { return false }
        let start = event.locationInWindow
        let deadline = Date(timeIntervalSinceNow: Self.holdInterval)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking, dequeue: false) {
            if next.type == .leftMouseUp { return false }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 { return false }
            _ = window.nextEvent(matching: [.leftMouseDragged], until: .distantPast, inMode: .eventTracking, dequeue: true)
        }
        return true
    }

    static let holdInterval: TimeInterval = 0.45

    /// Messages' tapback focus: the transcript blurs, the held bubble lifts in
    /// place with a small pop, and a glass reactions capsule appears above it.
    func showReactionFocus(_ model: MacMessageRowModel, in row: MacMessageRowView) {
        replyFocus?.removeFromSuperview()
        let focus = MacReplyFocusView(frame: scrollView.frame)
        focus.autoresizingMask = [.width, .height]
        focus.messageID = model.message.id
        focus.onDismiss = { [weak self] in self?.dismissReactionFocus() }
        view.addSubview(focus, positioned: .above, relativeTo: scrollView)
        let frame = row.convert(row.bounds, to: focus)
        let mine = model.message.reactions.first { $0.participantID == store.meID }?.reaction
        let picker = MacReactionPickerView(current: mine) { [weak self] reaction in
            // Fold the picker away first; the tapback lands after, like Messages.
            let next = mine == reaction ? nil : reaction
            self?.dismissReactionFocus {
                self?.store.react(messageID: model.message.id, reaction: next)
                if next != nil { self?.landReactionBadge(messageID: model.message.id) }
            }
        }
        reactionPicker = picker
        let bubble = row.convert(row.rowLayout?.bubbleFrame ?? row.contentFrame, to: focus)
        focus.present(snapshotOf: row, from: frame, to: frame, pop: true)
        focus.showReactionPicker(picker, bubble: bubble, outgoing: model.isOutgoing)
        replyFocus = focus
    }

    private var reactionPicker: MacReactionPickerView?

    func dismissReactionFocus(then completion: (@MainActor () -> Void)? = nil) {
        reactionPicker = nil
        restoreFocusAfterReactionFocus(replyFocus)
        dismissReplyFocus(sent: false, then: completion)
    }

    /// A new tapback lands as a tiny badge that swells (slight overshoot),
    /// after the picker has folded away, as on iOS Messages.
    func landReactionBadge(messageID: String) {
        guard let index = rows.firstIndex(where: { if case let .message(model) = $0 { return model.message.id == messageID } else { return false } }),
              let row = rowView(at: index), !row.badge.isHidden, let layer = row.badge.layer else { return }
        let bounds = row.badge.bounds
        let scaled = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0), CATransform3DMakeScale(0.1, 0.1, 1)),
            CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        )
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: scaled)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.mass = 1
        grow.stiffness = 380
        grow.damping = 22
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "land")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.08
        layer.add(fade, forKey: "landFade")
    }

    private func link(in model: MacMessageRowModel, at point: CGPoint, width: CGFloat) -> URL? {
        textAttribute(.macConversationLink, in: model, at: point, width: width)
    }

    private func textAttribute<Value>(_ key: NSAttributedString.Key, in model: MacMessageRowModel, at point: CGPoint, width: CGFloat) -> Value? {
        let text = layoutCache.text(model)
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < text.length else { return nil }
        return text.attribute(key, at: index, effectiveRange: nil) as? Value
    }

    private weak var tapbackPopover: NSPopover?

    func showTapbackBar(_ model: MacMessageRowModel, in rowView: MacMessageRowView) {
        tapbackPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let mine = model.message.reactions.first { $0.participantID == store.meID }?.reaction
        popover.contentViewController = MacTapbackBarController(current: mine) { [weak self, weak popover] reaction in
            popover?.close()
            self?.store.react(messageID: model.message.id, reaction: mine == reaction ? nil : reaction)
        }
        // Anchored at the bubble's leading (incoming) or trailing (outgoing)
        // top corner, like Messages, so it never spills over the sidebar or
        // centers over the rows above.
        let content = rowView.contentFrame
        // Popovers center on their anchor; offset by half the bar's width so
        // the bar starts at the bubble's edge.
        let half = (popover.contentViewController?.view.fittingSize.width ?? 200) / 2
        let anchorX = model.isOutgoing ? content.maxX - half : content.minX + half
        let anchor = CGRect(x: anchorX - 1, y: content.minY, width: 2, height: content.height)
        popover.show(relativeTo: anchor, of: rowView, preferredEdge: rowView.isFlipped ? .minY : .maxY)
        tapbackPopover = popover
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
        // Only stored messages can be answered or reacted to.
        if message.seq != nil {
            menu.addItem(item(String(localized: "conversation.menu.reply", defaultValue: "Reply", bundle: .module), "arrowshape.turn.up.left") { [weak self] in self?.enterReply(message) })
            menu.addItem(item(String(localized: "conversation.menu.tapback", defaultValue: "Tapback…", bundle: .module), "heart") { [weak self] in self?.showReactionFocus(model, in: rowView) })
        }
        if store.canEdit(message) {
            menu.addItem(item(String(localized: "conversation.menu.edit", defaultValue: "Edit", bundle: .module), "pencil") { [weak self] in self?.enterEdit(message) })
        }
        if store.canUnsend(message) {
            menu.addItem(item(String(localized: "conversation.menu.undoSend", defaultValue: "Undo Send", bundle: .module), "arrow.uturn.backward.circle") { [weak self] in
                self?.store.unsend(messageID: message.id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "conversation.menu.copy", defaultValue: "Copy", bundle: .module), "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        })
        if let translate = translateMenuItem(for: model) { menu.addItem(translate) }
        if message.isScheduled {
            // Send Later: the Edit menu's actions, with Cancel Send Later.
            for scheduledItem in sendLaterMenu(rowID: model.rowID, anchor: rowView, cancelTitle: true).items {
                scheduledItem.menu?.removeItem(scheduledItem)
                menu.addItem(scheduledItem)
            }
        } else if message.delivery?.isFailed == true {
            menu.addItem(item(String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module), "arrow.clockwise") { [weak self] in self?.store.retry(rowID: model.rowID) })
            menu.addItem(item(String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module), "trash") { [weak self] in self?.deleteLocally([model.rowID]) })
        } else {
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "conversation.menu.deleteEllipsis", defaultValue: "Delete…", bundle: .module), "trash") { [weak self] in self?.confirmDelete(model) })
        }
        menu.addItem(.separator())
        let timesTitle = showsTimes
            ? String(localized: "conversation.menu.hideTimes", defaultValue: "Hide Times", bundle: .module)
            : String(localized: "conversation.menu.showTimes", defaultValue: "Show Times", bundle: .module)
        menu.addItem(item(timesTitle, "clock") { [weak self] in self?.toggleShowsTimes() })
        addPollMenuItems(to: menu, model: model, rowView: rowView)
        // Messages darkens the bubble while its menu is open.
        menuHighlight.begin(rowView)
        menu.delegate = menuHighlight
        return menu
    }

    private let menuHighlight = MacMenuBubbleHighlight()
    private var menuHighlightReleaseTask: Task<Void, Never>?

    private func showRetryMenu(_ model: MacMessageRowModel, at point: NSPoint, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module)) { [weak self] in
            self?.store.retry(rowID: model.rowID)
        })
        menu.addItem(MacClosureMenuItem(title: String(localized: "conversation.select.delete", defaultValue: "Delete", bundle: .module)) { [weak self] in
            self?.deleteLocally([model.rowID])
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

    // MARK: Lab automation (DEBUG dev runner only)

    #if DEBUG
    /// Drives the same paths a person uses, for scripted verification.
    public func labCommand(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return "error empty" }
        let argument = parts.count > 1 ? parts[1] : ""
        if let reply = catchUpLabCommand(verb) { return reply }
        if verb.hasPrefix("sl.") { return sendLaterLabCommand(verb, argument) }
        switch verb {
        case "type":
            view.window?.makeFirstResponder(composer.textView)
            composer.textView.insertText(argument.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: composer.textView.selectedRange())
            return "ok"
        case "send":
            composer.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            return "ok"
        case "effect":
            // effect <name>: send the draft with that effect; effect replay: replay the newest.
            if argument == "state" { return effectLabState() }
            if argument == "replay" {
                guard let id = rows.last(where: { if case let .message(m) = $0 { return m.message.effect != nil } else { return false } })?.id else { return "error none" }
                replayEffect(rowID: id)
                return "ok"
            }
            guard let effect = ConversationMessageEffect(rawValue: argument) else { return "error unknown effect" }
            sendWithEffect(effect)
            return "ok"
        case "composer":
            let host = composer.superview
            return String(format: "field %.1f composer %@ inWindow %@ host %@ hostInWindow %@", composer.fieldHeight, NSStringFromRect(composer.frame), NSStringFromRect(composer.convert(composer.bounds, to: nil)), NSStringFromRect(host?.frame ?? .zero), NSStringFromRect(host.map { $0.convert($0.bounds, to: nil) } ?? .zero))
        case "insets":
            let last = rows.last.map { row -> String in
                switch row { case .message: return "message"; case .typing: return "typing"; default: return "other" }
            } ?? "none"
            return String(format: "bottom %.1f trailing %.1f last %@ maxOffset %.1f origin %.1f", scrollView.contentInsets.bottom, lastRowTrailingSpace(), last, maxOffset, scrollView.contentView.bounds.origin.y)
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
        case "times":
            toggleShowsTimes()
            return showsTimes ? "shown" : "hidden"
        case "reveal":
            // A held swipe-left at this finger travel (points).
            sizeTimestampReveal()
            let shift = min(max(0, (Double(argument) ?? 0) - 14) * 0.4, timestampRevealDistance)
            setTimestampReveal(shift / timestampRevealDistance)
            return "shift \(shift) of \(timestampRevealDistance)"
        case "statusrows":
            // Status rows and the unavailability notice, newest last.
            return rows.compactMap { row -> String? in
                switch row {
                case let .systemEvent(_, text): return "{\(text.text)}"
                case let .unavailability(name, messageID): return "(silenced \(name)\(messageID == nil ? "" : " notify"))"
                case let .message(model): return model.footer == .none ? nil : "footer \(model.footer)"
                default: return nil
                }
            }.suffix(Int(argument) ?? 8).joined(separator: " | ")
        case "notifyanyway":
            guard let message = store.notifyAnywayMessage else { return "error nothing to notify" }
            store.notifyAnyway(messageID: message.id)
            return "ok"
        case "rows":
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            let ids = (visible.location..<min(rows.count, visible.location + visible.length)).compactMap { messageModel(at: $0)?.message.id }
            return "visible \(ids.joined(separator: ","))"
        case "tapback", "menu", "reply", "edit", "hold", "hover", "save":
            guard let index = lastMessageRow(matching: argument), let model = messageModel(at: index) else { return "error no row" }
            tableView.scrollRowToVisible(index)
            guard let rowView = rowView(at: index) else { return "error not visible" }
            switch verb {
            case "tapback": showTapbackBar(model, in: rowView)
            case "hold": showReactionFocus(model, in: rowView)
            case "hover": rowView.saveButton.isHidden = rowView.rowLayout?.imageFrames.isEmpty ?? true
            case "save": rowView.saveButton.performClick(nil)
            case "reply": enterReply(model.message)
            case "edit": enterEdit(model.message)
            default:
                let point = NSPoint(x: rowView.contentFrame.midX, y: rowView.contentFrame.midY)
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: rowView.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                if let event, let menu = contextMenu(for: event, in: tableView) {
                    // Hold the highlight briefly so a capture can see it, as with an open menu.
                    let titles = menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: "|")
                    menuHighlightReleaseTask?.cancel()
                    menuHighlightReleaseTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        self?.menuHighlight.end()
                    }
                    return "menu " + titles
                }
            }
            return "ok"
        case "clickreplies", "clickquote":
            // A real single click on the row's replies link or reply quote.
            guard let index = rows.indices.last(where: { index in
                guard let model = messageModel(at: index), model.message.text.localizedCaseInsensitiveContains(argument) || argument.isEmpty else { return false }
                return verb == "clickreplies" ? model.message.replyCount > 0 : model.message.replyToID != nil
            }) else { return "error no row" }
            tableView.scrollRowToVisible(index)
            guard let rowView = rowView(at: index) else { return "error not visible" }
            let target = verb == "clickreplies" ? rowView.repliesLabel.frame : (rowView.rowLayout?.quoteFrame ?? .zero)
            let point = rowView.convert(NSPoint(x: target.midX, y: target.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return "error event" }
            return handleClick(event, in: tableView) ? "ok thread \(threadRootID ?? "-")" : "error unhandled"
        case "undo":
            // Edit > Undo: the "Undo Send?" alert for my last message.
            undo(nil)
            return "ok"
        case "notunsent":
            // Clicks the newest "(!) Not Unsent" notice.
            guard let notice = rows.reversed().lazy.compactMap({ row -> ConversationNotice? in
                if case let .notice(notice) = row, notice.failure != nil { return notice } else { return nil }
            }).first else { return "error no failed notice" }
            presentNotUnsent(messageID: notice.messageID)
            return "ok"
        case "unsend", "delete", "retry":
            // The same paths the context menu runs (delete skips its confirmation).
            guard let index = lastMessageRow(matching: argument), let model = messageModel(at: index) else { return "error no row" }
            switch verb {
            case "unsend":
                guard store.canUnsend(model.message) else { return "error not unsendable" }
                store.unsend(messageID: model.message.id)
            case "delete": deleteLocally([model.rowID])
            default: store.retry(rowID: model.rowID)
            }
            return "ok"
        case "react":
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2, let index = lastMessageRow(matching: bits[0]), let model = messageModel(at: index),
                  let reaction = ConversationReaction(rawValue: bits[1]) else { return "error usage react <row-match> <reaction>" }
            store.react(messageID: model.message.id, reaction: reaction)
            return "ok"
        case "poll":
            return pollLabCommand(argument)
        case "translate", "translateconv", "translation", "untranslate", "toggletranslation", "translationindicator", "translatemenu":
            return labTranslationCommand(verb, argument)
        case "escape":
            tapbackPopover?.close()
            exitReplyOrEdit()
            return "ok"
        #if DEBUG
        case "multireact":
            // Scrolls to the newest loaded message carrying two or more tapback kinds.
            if argument == "make",
               let index = rows.indices.reversed().first(where: { messageModel(at: $0).map { $0.reactionKinds.count == 1 && $0.myReactions.isEmpty } ?? false }),
               let model = messageModel(at: index) {
                let other = ConversationReaction.allCases.first { !model.reactionKinds.contains($0) } ?? .heart
                store.react(messageID: model.message.id, reaction: other)
            }
            guard let index = rows.indices.reversed().first(where: { (messageModel(at: $0)?.reactionKinds.count ?? 0) >= 2 }),
                  let model = messageModel(at: index) else { return "none" }
            isPinnedToBottom = false
            tableView.scrollRowToVisible(index)
            return "found \(model.message.id) \(model.reactionKinds.map(\.rawValue).joined(separator: ","))"
        case "slowmo":
            // Core Animation runs this many times slower, so window captures
            // can sample short transitions.
            let factor = max(1, Double(argument) ?? 1)
            view.window?.contentView?.layer?.speed = Float(1 / factor)
            return "ok"
        case "faketyping":
            debugTyping = argument == "on"
            storeDidChange(.typing)
            return "ok"
        case "trace":
            let dump = traceLog.joined(separator: "\n")
            traceLog = []
            return "trace\n" + dump
        #endif
        case "mention":
            return mentionLabCommand(argument)
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
            case "photo": return !model.message.attachments.isEmpty && model.message.seq != nil
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
            if !showsTimes { sizeTimestampReveal() }
            return true
        case .changed:
            guard swipeRowID != nil || swipeAccumulatedX != 0 || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
            swipeAccumulatedX += event.scrollingDeltaX
            if swipeAccumulatedX > 0, let id = swipeRowID, let index = rowIndex[id],
               let container = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacMessageContainerView {
                container.replyDrag = min(80, swipeAccumulatedX * 0.8)
            } else if swipeAccumulatedX < 0, !showsTimes {
                // Messages for Mac shares the iOS transcript: 0.4x the finger
                // past a 14 pt dead zone, stopping dead at a full reveal.
                let shift = min(max(0, -swipeAccumulatedX - 14) * 0.4, timestampRevealDistance)
                setTimestampReveal(shift / timestampRevealDistance)
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
            if !showsTimes { setTimestampReveal(0, animated: true) }
            swipeRowID = nil
            swipeAccumulatedX = 0
            return true
        default:
            return false
        }
    }

    func setTimestampReveal(_ value: CGFloat, animated: Bool = false) {
        timestampsRevealed = value
        let apply = {
            for index in 0..<self.rows.count {
                guard let container = self.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacMessageContainerView else { continue }
                if animated { container.animator().timestampReveal = value } else { container.timestampReveal = value }
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                // An exponential settle (time constant ~0.114 s), as on iOS.
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.95, 0.45, 1)
                apply()
            }
        } else {
            apply()
        }
    }

    /// The widest visible time ends at the side margin, clear of the bubbles.
    private func sizeTimestampReveal() {
        let visible = tableView.rows(in: tableView.visibleRect)
        var widest: CGFloat = 0
        for index in visible.lowerBound..<visible.upperBound {
            guard let container = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacMessageContainerView else { continue }
            widest = max(widest, container.timeLabelWidth)
        }
        timestampRevealDistance = MacMessageContainerView.revealDistance(forTimeWidth: widest > 0 ? widest : 44)
        for index in visible.lowerBound..<visible.upperBound {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacMessageContainerView)?.timestampRevealDistance = timestampRevealDistance
        }
    }

    /// Context menu "Show Times" / "Hide Times" and View > Show Times.
    func toggleShowsTimes() {
        if !showsTimes { sizeTimestampReveal() }
        showsTimes.toggle()
        setTimestampReveal(showsTimes ? 1 : 0, animated: true)
    }
}

/// Hosts a message row with its top spacing, swipe offsets and revealed time.
final class MacMessageContainerView: MacFlippedView {
    let row = MacMessageRowView()
    private let timeLabel = makeMacLabel()
    var topSpacing: CGFloat = 0 { didSet { needsLayout = true } }
    @objc dynamic var replyDrag: CGFloat = 0 { didSet { needsLayout = true } }
    @objc dynamic var timestampReveal: CGFloat = 0 { didSet { needsLayout = true } }
    var timestampRevealDistance: CGFloat = 60 { didSet { needsLayout = true } }
    var timeLabelWidth: CGFloat { timeLabel.frame.width }

    /// Bubble travel that clears a time of this width by the side margin.
    static func revealDistance(forTimeWidth width: CGFloat) -> CGFloat {
        (width + MacConversationTheme.sideMargin).rounded()
    }

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
        let reveal = timestampReveal * timestampRevealDistance
        let isOutgoing = row.model?.isOutgoing ?? false
        let shift = replyDrag - (isOutgoing ? reveal : 0)
        row.frame = CGRect(x: shift, y: topSpacing, width: bounds.width, height: bounds.height - topSpacing)
        timeLabel.stringValue = row.model?.message.sentAt.formatted(date: .omitted, time: .shortened) ?? ""
        timeLabel.sizeToFit()
        let content = row.contentFrame
        // The time slides in from 8 pt past the edge (no fade), a little
        // faster than the bubbles, and ends at the side margin.
        let travel = timeLabel.frame.width + 8 + MacConversationTheme.sideMargin
        timeLabel.frame.origin = CGPoint(x: bounds.width + 8 - travel * timestampReveal, y: topSpacing + content.midY - timeLabel.frame.height / 2)
        timeLabel.alphaValue = timestampReveal > 0 ? 1 : 0
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
            button.setAccessibilityLabel(ConversationAccessibilityText.tapbackName(reaction))
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

    /// Keyboard tapback (⌘T): digits pick, Esc cancels.
    var onKeyDown: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { onKeyDown != nil }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let onPicker = (accessoryView as? MacReactionPickerView)?.contains(point) ?? (accessoryView?.frame.contains(point) == true)
        if !snapshotView.frame.contains(point), !onPicker { onDismiss?() }
    }

    // AppKit-backed layers anchor at their origin, so position == frame origin.
    private var accessoryView: NSView?

    /// Measured against Messages: the capsule sits just above the bubble,
    /// starting 45 pt outside its leading edge (outgoing) or ending 45 pt
    /// outside its trailing edge (incoming); the emoji circle hangs beside the
    /// bubble's top corner with two dots trailing toward it.
    func showReactionPicker(_ picker: MacReactionPickerView, bubble: CGRect, outgoing: Bool) {
        picker.layoutSubtreeIfNeeded()
        let size = picker.capsuleSize
        let outside: CGFloat = 45
        var x = outgoing ? bubble.minX - outside : bubble.maxX + outside - size.width
        x = min(max(8, x), bounds.width - size.width - 8)
        let capsule = CGRect(x: x, y: max(8, bubble.minY - size.height - 4), width: size.width, height: size.height)
        let circleCenter = CGPoint(x: outgoing ? bubble.minX - 25 : bubble.maxX + 25, y: bubble.minY + 12)
        picker.frame = bounds
        picker.autoresizingMask = [.width, .height]
        picker.place(capsule: capsule, circleCenter: circleCenter, outgoing: outgoing)
        addSubview(picker)
        accessoryView = picker
        picker.wantsLayer = true
        // Messages' (shared ChatKit) picker grows out of a dot at the bubble's
        // top corner; see MacReactionPickerView.animateIn.
        picker.animateIn(seed: CGPoint(x: outgoing ? bubble.minX + 9 : bubble.maxX - 9, y: bubble.minY - 8))
    }

    func showAccessory(_ content: NSView, anchoredAbove anchor: CGRect, trailing: Bool) {
        let glass: NSView
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.contentView = content
            effect.cornerRadius = 21
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 21
            effect.addSubview(content)
            glass = effect
        }
        let size = content.fittingSize
        let width = max(size.width, 100), height = max(size.height, 42)
        let x = trailing ? anchor.maxX - width : anchor.minX
        glass.frame = CGRect(x: min(max(8, x), bounds.width - width - 8), y: max(8, anchor.minY - height - 6), width: width, height: height)
        content.frame = CGRect(origin: .zero, size: glass.frame.size)
        addSubview(glass)
        accessoryView = glass
        glass.wantsLayer = true
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6
        pop.toValue = 1
        pop.damping = 18
        pop.stiffness = 320
        pop.duration = pop.settlingDuration
        glass.layer?.add(pop, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        glass.layer?.add(fade, forKey: "fade")
    }

    func present(snapshotOf row: NSView, from source: CGRect, to target: CGRect, pop: Bool = false) {
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
        if source != target { snapshot.add(lift, forKey: "lift") }
        if pop {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [1, 1.04, 1]
            scale.keyTimes = [0, 0.4, 1]
            scale.duration = 0.3
            snapshot.add(scale, forKey: "pop")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            blur.animator().alphaValue = 1
        }
    }

    func dismiss(returningTo destination: CGRect?, then completion: (@MainActor () -> Void)? = nil) {
        if let picker = accessoryView as? MacReactionPickerView {
            picker.animateOut()
        } else if let accessoryView {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                accessoryView.animator().alphaValue = 0
            }
        }
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
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                completion?()
            }
        })
    }
}

/// Hosts one send flight above the window's content (composer included).
final class MacFlightOverlayView: NSView {
    /// Body and text, scaled together for the send dip.
    private let flight = CALayer()
    private let body = CAShapeLayer()
    private let textLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(flight)
        flight.addSublayer(body)
        flight.addSublayer(textLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The Messages bubble (tail included) for `rect` in this unflipped
    /// view: the shared geometry is drawn y-down, so build it flipped.
    private func bubblePath(_ rect: CGRect, tail: Bool) -> CGPath {
        let height = bounds.height
        let flipped = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        let t = MacConversationTheme.self
        let path = ConversationBubbleGeometry.path(
            in: flipped, side: .trailing, tail: tail,
            radius: t.bubbleCornerRadius, tailWidth: t.tailWidth, tailDrop: t.tailDrop, style: .macOS
        )
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        return path.copy(using: &flip) ?? path
    }

    func fly(color: CGColor, text: CGImage?, textSize: CGSize, fromBody: CGRect, toBody: CGRect,
             fromText: CGRect, toText: CGRect, tail: Bool, completion: @escaping @MainActor () -> Void) {
        let scale = window?.backingScaleFactor ?? 2
        let fromPath = bubblePath(fromBody, tail: tail)
        let toPath = bubblePath(toBody, tail: tail)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flight.frame = bounds
        body.frame = bounds
        body.fillColor = color
        body.path = toPath
        textLayer.contents = text
        textLayer.contentsScale = scale
        textLayer.frame = toText
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        func spring(_ keyPath: String, _ from: Any, _ to: Any) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.mass = 1
            animation.stiffness = 240
            // Near-critical: lands without the 7 pt overshoot an underdamped
            // spring gave the wide-to-narrow width change.
            animation.damping = 30
            animation.duration = animation.settlingDuration
            return animation
        }
        // One path spring moves and reshapes the tailed body.
        body.add(spring("path", fromPath, toPath), forKey: "p")
        textLayer.add(spring("position", NSValue(point: CGPoint(x: fromText.midX, y: fromText.midY)), NSValue(point: CGPoint(x: toText.midX, y: toText.midY))), forKey: "p")
        addSendDip(pivot: CGPoint(x: toBody.maxX, y: toBody.midY), fieldHeight: fromBody.height)
        CATransaction.commit()
    }

    /// ChatKit's glass send dip (CASpringAnimation(SendAnimation), the same
    /// on macOS): an additive spring down to a factor set by the field
    /// height, and one back up from 0.185 s, about the bubble's trailing
    /// edge. Run at the 1.15x rate measured against iOS Messages.
    private func addSendDip(pivot: CGPoint, fieldHeight: CGFloat) {
        // Mac ChatKit's _ck_scaleDownFactorForEntryViewSize: (height only).
        let factor = min(0.9, max(0.7, 0.7 + (fieldHeight - 40) / 1200))
        let center = CGPoint(x: flight.bounds.midX, y: flight.bounds.midY)
        func about(_ s: CGFloat) -> CATransform3D {
            var m = CATransform3DMakeTranslation(center.x - pivot.x, center.y - pivot.y, 0)
            m = CATransform3DConcat(m, CATransform3DMakeScale(s, s, 1))
            return CATransform3DConcat(m, CATransform3DMakeTranslation(pivot.x - center.x, pivot.y - center.y, 0))
        }
        let now = flight.convertTime(CACurrentMediaTime(), from: nil)
        for (target, stiffness, delay, key) in [(factor, 310.0, 0.0, "dipDown"), (1 / factor, 320.0, 0.185, "dipUp")] {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 2
            spring.stiffness = stiffness
            spring.damping = 38
            spring.isAdditive = true
            spring.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.toValue = NSValue(caTransform3D: about(target))
            spring.duration = spring.settlingDuration
            spring.speed = 1.15
            spring.beginTime = now + delay / 1.15
            spring.fillMode = .both
            // Both stay until the flight lands; dropping one early would
            // leave the other's scale applied.
            spring.isRemovedOnCompletion = false
            flight.add(spring, forKey: key)
        }
    }
}

/// The reply-focus backdrop and thread: darkened blur over the transcript
/// and the thread's rows in a bottom-anchored scroll view.
final class MacThreadFocusView: NSView {
    var onDismiss: (() -> Void)?
    private let blur = NSVisualEffectView()
    private let dim = NSView()
    private let content = MacFlippedView()
    private var firstShow = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        blur.material = .underWindowBackground
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        // Measured: Messages darkens the blurred transcript to near black.
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        dim.frame = bounds
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        setAccessibilityIdentifier("conversation.threadFocus")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = content.convert(event.locationInWindow, from: nil)
        if !content.subviews.contains(where: { $0.frame.contains(point) }) { onDismiss?() }
    }

    func show(_ placed: [(NSView, CGRect)], animated: Bool) {
        content.subviews.forEach { $0.removeFromSuperview() }
        for (view, frame) in placed {
            view.frame = frame
            content.addSubview(view)
        }
        guard animated, firstShow else { return }
        firstShow = false
        for view in [blur, dim] {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                view.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }
}

/// Messages' reaction picker: a Liquid Glass capsule of tapbacks and a
/// separate emoji circle with a trail of dots, over the reaction focus.
final class MacReactionPickerView: MacFlippedView {
    private let capsule: NSView
    private let circle: NSView
    private let dots = [MacFlippedView(), MacFlippedView()]
    private let stack = NSStackView()
    /// Clips the tapbacks to the capsule's current outline while it grows,
    /// so the capsule reveals them in place instead of dragging them along.
    private let clip = MacFlippedView()
    private var finalCapsule: CGRect = .zero
    private var seed: CGPoint = .zero
    private let onPick: (ConversationReaction) -> Void
    private let current: ConversationReaction?

    init(current: ConversationReaction?, onPick: @escaping (ConversationReaction) -> Void) {
        self.current = current
        self.onPick = onPick
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 21
            capsule = glass
            let round = NSGlassEffectView()
            round.cornerRadius = 17.5
            circle = round
        } else {
            capsule = NSVisualEffectView()
            circle = NSVisualEffectView()
        }
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for (index, reaction) in ConversationReaction.allCases.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(picked(_:)))
            button.isBordered = false
            button.attributedTitle = MacReactionPickerView.glyph(reaction)
            button.tag = index
            button.wantsLayer = true
            button.layer?.cornerRadius = 16
            if reaction == current { button.layer?.backgroundColor = NSColor.systemBlue.cgColor }
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.setAccessibilityLabel(ConversationAccessibilityText.tapbackName(reaction))
            button.setAccessibilityIdentifier("conversation.tapback.\(reaction.rawValue)")
            stack.addArrangedSubview(button)
        }
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(stack)
        let smiley = NSImageView(image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) ?? NSImage())
        smiley.contentTintColor = .secondaryLabelColor
        if #available(macOS 26.0, *), let glass = circle as? NSGlassEffectView {
            glass.contentView = smiley
        } else {
            circle.addSubview(smiley)
        }
        for dot in dots {
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            addSubview(dot)
        }
        addSubview(circle)
        addSubview(capsule)
        addSubview(clip)
        setAccessibilityIdentifier("conversation.reactionPicker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var capsuleSize: CGSize {
        CGSize(width: CGFloat(ConversationReaction.allCases.count) * 36 + 12, height: 42)
    }

    func place(capsule frame: CGRect, circleCenter: CGPoint, outgoing: Bool) {
        finalCapsule = frame
        capsule.frame = frame
        clip.frame = frame
        clip.layer?.cornerRadius = frame.height / 2
        stack.frame = CGRect(origin: .zero, size: frame.size)
        let d: CGFloat = 35
        circle.frame = CGRect(x: circleCenter.x - d / 2, y: circleCenter.y - d / 2, width: d, height: d)
        circle.subviews.first?.frame = circle.bounds
        if #available(macOS 26.0, *) { (circle as? NSGlassEffectView)?.contentView?.frame = circle.bounds }
        // Two dots trail from the circle toward the bubble's corner below it.
        let away: CGFloat = outgoing ? -1 : 1
        dots[0].frame = CGRect(x: circleCenter.x + away * 17 - 4, y: circleCenter.y + 19, width: 8, height: 8)
        dots[1].frame = CGRect(x: circleCenter.x + away * 25 - 2.5, y: circleCenter.y + 30, width: 5, height: 5)
        for dot in dots { dot.layer?.cornerRadius = dot.frame.width / 2 }
    }

    func contains(_ point: CGPoint) -> Bool {
        capsule.frame.contains(point) || circle.frame.contains(point)
    }

    /// `keepRadius` holds the current rounding while shrinking, so a
    /// collapsing capsule stays round instead of squaring off.
    private func setCapsuleFrame(_ frame: CGRect, animated: Bool, keepRadius: Bool = false) {
        let target = animated ? capsule.animator() : capsule
        target.frame = frame
        (animated ? clip.animator() : clip).frame = frame
        (animated ? stack.animator() : stack).setFrameOrigin(CGPoint(x: finalCapsule.minX - frame.minX, y: finalCapsule.minY - frame.minY))
        guard !keepRadius else { return }
        let radius = min(finalCapsule.height, min(frame.width, frame.height)) / 2
        clip.layer?.cornerRadius = radius
        if #available(macOS 26.0, *) { (capsule as? NSGlassEffectView)?.cornerRadius = radius }
    }

    private func circleFrame(diameter: CGFloat, centerY: CGFloat) -> CGRect {
        CGRect(x: seed.x - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter)
    }

    /// iOS 26 Messages' measured choreography (the Mac picker is the same
    /// ChatKit balloon): a dot at the bubble's corner swells into a circle,
    /// stretches into the capsule, and the tapbacks pop in left to right;
    /// the emoji circle and its dots follow.
    func animateIn(seed: CGPoint) {
        self.seed = seed
        let final = finalCapsule
        setCapsuleFrame(circleFrame(diameter: 10, centerY: seed.y), animated: false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            setCapsuleFrame(circleFrame(diameter: final.height, centerY: final.midY + 4), animated: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isFolding else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.34
                    // Close to a critically damped spring: fast start, no overshoot.
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                    context.allowsImplicitAnimation = true
                    self.setCapsuleFrame(final, animated: true)
                }
            }
        })
        let now = CACurrentMediaTime()
        for (index, view) in stack.arrangedSubviews.enumerated() {
            view.wantsLayer = true
            pop(view, from: 0.3, at: now + 0.14 + Double(index) * 0.035, bounce: true)
        }
        for dot in dots { pop(dot, from: 0.2, at: now + 0.18, bounce: true) }
        pop(circle, from: 0.2, at: now + 0.22, bounce: true)
    }

    private var isFolding = false

    /// Reverse: tapbacks fade, the capsule folds back into its dot (~0.3 s).
    func animateOut() {
        isFolding = true
        capsule.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            for view in stack.arrangedSubviews + [circle] + dots { view.animator().alphaValue = 0 }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            setCapsuleFrame(circleFrame(diameter: finalCapsule.height - 2, centerY: finalCapsule.midY + 6), animated: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    context.allowsImplicitAnimation = true
                    self.setCapsuleFrame(self.circleFrame(diameter: 4, centerY: self.seed.y), animated: true, keepRadius: true)
                    self.capsule.animator().alphaValue = 0
                    self.clip.animator().alphaValue = 0
                }
            }
        })
    }

    /// Scale-from-center pop on a layer-backed view (AppKit layers anchor at
    /// their origin, so the scale is composed about the bounds center).
    private func pop(_ view: NSView, from scale: CGFloat, at time: CFTimeInterval, bounce: Bool) {
        guard let layer = view.layer else { return }
        let b = view.bounds
        let start = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-b.midX, -b.midY, 0), CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(b.midX, b.midY, 0)
        )
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: start)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.mass = 1
        grow.stiffness = 300
        grow.damping = bounce ? 20 : 35
        grow.duration = grow.settlingDuration
        grow.beginTime = time
        grow.fillMode = .backwards
        layer.add(grow, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.08
        fade.beginTime = time
        fade.fillMode = .backwards
        layer.add(fade, forKey: "popFade")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return contains(local) ? super.hitTest(point) : nil
    }

    @objc private func picked(_ sender: NSButton) {
        onPick(ConversationReaction.allCases[sender.tag])
    }

    private static func glyph(_ reaction: ConversationReaction) -> NSAttributedString {
        let base = NSMutableAttributedString(attributedString: MacTapbackGlyph.text(reaction))
        let size: CGFloat = reaction == .haha ? 12.5 : 22
        base.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .black), range: NSRange(location: 0, length: base.length))
        return base
    }
}

/// Dims the pressed bubble for as long as its context menu is open.
@MainActor
final class MacMenuBubbleHighlight: NSObject, NSMenuDelegate {
    private weak var row: MacMessageRowView?

    func begin(_ row: MacMessageRowView) {
        end()
        self.row = row
        row.bubble.opacity = 0.72
    }

    func end() {
        row?.bubble.opacity = 1
        row = nil
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated { end() }
    }
}
// MARK: - Catch-up

/// Messages' "Go Up" button: selecting a conversation with unread messages
/// lands on the newest one and offers a glass up-arrow in the transcript's
/// top-right corner that jumps to the first unread message. It leaves once
/// that message has been on screen.
extension MacConversationViewController {
    fileprivate func installCatchUp() {
        let label = String(localized: "conversation.catchUp.label", defaultValue: "Scroll to first unread message", bundle: .module)
        catchUpButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        catchUpButton.imagePosition = .imageOnly
        if #available(macOS 26.0, *) {
            catchUpButton.bezelStyle = .glass
            catchUpButton.borderShape = .circle
        } else {
            catchUpButton.bezelStyle = .circular
        }
        catchUpButton.controlSize = .large
        catchUpButton.contentTintColor = .systemBlue
        catchUpButton.target = self
        catchUpButton.action = #selector(catchUpClicked)
        catchUpButton.setAccessibilityLabel(label)
        catchUpButton.setAccessibilityIdentifier("conversation.catchUp")
        catchUpButton.toolTip = label
        catchUpButton.isHidden = true
        catchUpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(catchUpButton)
        NSLayoutConstraint.activate([
            catchUpButton.widthAnchor.constraint(equalToConstant: 32),
            catchUpButton.heightAnchor.constraint(equalToConstant: 32),
            catchUpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            catchUpButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])
    }

    /// Hides the arrow once the first unread message reaches the visible
    /// transcript; shows it while that message is above (or not yet loaded).
    fileprivate func updateCatchUp() {
        guard store.catchUpMarker != nil, hasPositioned else {
            setCatchUpVisible(false)
            return
        }
        if let target = store.catchUpTarget, let index = rowIndex[target.rowID] {
            let visibleTop = scrollView.contentView.bounds.minY + scrollView.contentInsets.top
            if tableView.rect(ofRow: index).maxY > visibleTop {
                store.dismissCatchUp()
                setCatchUpVisible(false)
                return
            }
        }
        // ChatKit: "A message that I sent is visible on screen. Do not show
        // catch up button." Replying there means the reader has caught up.
        if let marker = store.catchUpMarker {
            let range = tableView.rows(in: scrollView.contentView.bounds)
            for index in range.location..<min(rows.count, range.location + range.length) {
                guard case let .message(model) = rows[index], model.isOutgoing,
                      (store.message(rowID: model.rowID)?.seq ?? .max) > marker else { continue }
                store.dismissCatchUp()
                setCatchUpVisible(false)
                return
            }
        }
        setCatchUpVisible(true)
    }

    private func setCatchUpVisible(_ visible: Bool) {
        guard catchUpButton.isHidden == visible else { return }
        catchUpButton.isHidden = !visible
    }

    @objc private func catchUpClicked() {
        catchUpButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let rowID = await self.store.loadCatchUpTarget()
            self.catchUpButton.isEnabled = true
            guard let rowID else { return }
            self.jumpToRow(rowID)
        }
    }

    /// Scrolls so the row sits just under the toolbar.
    fileprivate func jumpToRow(_ rowID: String) {
        tableView.layoutSubtreeIfNeeded()
        guard let index = rowIndex[rowID] else { return }
        isPinnedToBottom = false
        let top = scrollView.contentInsets.top
        let y = min(max(-top, tableView.rect(ofRow: index).minY - top - 8), maxOffset)
        store.dismissCatchUp()
        setCatchUpVisible(false)
        animateScroll(to: NSPoint(x: 0, y: y), duration: 0.35, timing: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    /// Lab verbs: `catchup` (state), `catchup go`, `unread`.
    fileprivate func catchUpLabCommand(_ verb: String) -> String? {
        switch verb {
        case "catchup":
            return "catchup \(catchUpButton.isHidden ? "hidden" : "visible") marker \(store.catchUpMarker.map(String.init) ?? "-") count \(store.catchUpCount) target \(store.catchUpTarget?.seq.map(String.init) ?? "-")"
        case "catchupgo":
            catchUpClicked()
            return "ok"
        case "unread":
            return "unread \(store.unreadCount) lastRead \(store.lastReadSeq) viewing \(store.isViewing) all \(MacConversationLab.unreadSummary())"
        default:
            return nil
        }
    }
}

/// Hosts the Undo Send pop above the transcript. Unflipped, so its layer's
/// origin is bottom-left; it never takes clicks.
private final class PopOverlayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
