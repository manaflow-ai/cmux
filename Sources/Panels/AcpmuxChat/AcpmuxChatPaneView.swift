import AppKit
import CmuxAcpmux
import Observation

/// The native acpmux chat pane: header with session picker, virtualized transcript,
/// permission card, queued prompts, and composer.
@MainActor
final class AcpmuxChatPaneView: AcpmuxFlippedView {
    let model: AcpmuxChatSessionModel
    let transcript: AcpmuxTranscriptView
    private let header = AcpmuxChatHeaderView(frame: .zero)
    let composer: AcpmuxComposerView
    private let permissionCard = AcpmuxPermissionCardView(frame: .zero)
    private let queueStrip = AcpmuxQueueStripView(frame: .zero)
    private let jumpPill = AcpmuxJumpToLatestPill()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var theme: AcpmuxChatTheme
    private var showsPermissionCard = false
    private var showsJumpPill = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(model: AcpmuxChatSessionModel, theme: AcpmuxChatTheme) {
        self.model = model
        self.theme = theme
        self.transcript = AcpmuxTranscriptView(model: model, theme: theme)
        self.composer = AcpmuxComposerView(theme: theme)
        super.init(frame: .zero)
        setAccessibilityIdentifier("acpmuxChat.pane")
        addSubview(transcript)
        addSubview(header)
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 12.5)
        addSubview(statusLabel)
        permissionCard.alphaValue = 0
        addSubview(permissionCard)
        addSubview(queueStrip)
        addSubview(composer)
        jumpPill.alphaValue = 0
        jumpPill.target = self
        jumpPill.action = #selector(jumpPressed)
        addSubview(jumpPill)

        header.pickerButton.target = self
        header.pickerButton.action = #selector(showSessionMenu)
        composer.onSubmit = { [weak self] text in self?.submit(text) }
        composer.onCancelTurn = { [weak self] in self?.model.cancelTurn() }
        composer.onHeightChange = { [weak self] in self?.relayout(animated: false) }
        permissionCard.onChoose = { [weak self] card, optionId in self?.model.respond(to: card, optionId: optionId) }
        queueStrip.onSteer = { [weak self] entry in self?.model.steer(entry) }
        queueStrip.onRemove = { [weak self] entry in self?.model.removeQueued(entry) }
        transcript.onScrollStateChanged = { [weak self] pinned, unread in self?.updateJumpPill(pinned: pinned, unread: unread) }
        transcript.onDidFlush = { [weak self] in self?.checkMorphTarget() }
        model.onTranscriptChanged = { [weak self] in self?.transcript.setNeedsFlush() }
        applyTheme()
        observeModel()
        transcript.setNeedsFlush()
    }

    func setTheme(_ theme: AcpmuxChatTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        transcript.setTheme(theme)
        composer.apply(theme: theme)
        applyTheme()
        renderChrome()
    }

    private func applyTheme() {
        layer?.backgroundColor = theme.background.cgColor
        statusLabel.textColor = theme.secondaryText
    }

    func focusComposer() {
        window?.makeFirstResponder(composer.textView)
    }

#if DEBUG
    /// Scripted interactions for DEBUG animation recordings.
    func performDebugAction(_ action: String) -> Bool {
        switch action {
        case "scroll_top": transcript.debugScroll(toTop: true)
        case "jump_latest": transcript.jumpToLatest()
        case "toggle_last_group": return transcript.debugToggleLastActivity()
        default: return false
        }
        return true
    }
#endif

    /// Appends `text` to the composer. Each newline submits, exactly like pressing Return.
    func receiveComposerInput(_ text: String) {
        var pending = ""
        for character in text {
            if character.isNewline {
                composer.textView.insertText(pending, replacementRange: NSRange(location: NSNotFound, length: 0))
                pending = ""
                composer.submitCurrentText()
            } else {
                pending.append(character)
            }
        }
        if !pending.isEmpty {
            composer.textView.insertText(pending, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    // MARK: - Model observation

    private func observeModel() {
        withObservationTracking {
            renderChrome()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    private func renderChrome() {
        let summary = model.summary
        let title = summary?.displayTitle ?? String(localized: "acpmuxChat.header.newSession", defaultValue: "New Session")
        let (status, color) = statusText(summary: summary)
        header.update(title: title, status: status, statusColor: color, theme: theme)
        composer.setWorking(model.isWorking)

        let harness = summary?.harness ?? model.newSessionHarness ?? model.catalog.defaultHarness
        composer.harnessChip.apply(title: harness ?? "acpmux", theme: theme)
        composer.harnessChip.menu = harnessMenu()
        let models = model.catalog.harness(named: summary?.harness)?.models ?? []
        composer.modelChip.isHidden = summary == nil || models.isEmpty
        let modelName = models.first { $0.id == summary?.model }?.name ?? summary?.model
            ?? String(localized: "acpmuxChat.composer.defaultModel", defaultValue: "Default model")
        composer.modelChip.apply(title: modelName, theme: theme)
        composer.modelChip.menu = modelMenu(models, current: summary?.model)

        queueStrip.update(model.queue, theme: theme)
        let pending = model.pendingPermission
        if let pending { permissionCard.update(pending, theme: theme) }
        let wantsCard = pending != nil
        let cardChanged = wantsCard != showsPermissionCard
        showsPermissionCard = wantsCard

        switch model.connectionState {
        case .connecting:
            statusLabel.stringValue = String(localized: "acpmuxChat.status.connecting", defaultValue: "Connecting to acpmux…")
        case .failed(let message):
            let format = String(localized: "acpmuxChat.status.unavailable", defaultValue: "acpmux is unavailable: %@")
            statusLabel.stringValue = String.localizedStringWithFormat(format, message)
        case .connected:
            statusLabel.stringValue = model.rows.isEmpty
                ? String(localized: "acpmuxChat.status.empty", defaultValue: "Send a message to start.")
                : ""
        }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        relayout(animated: cardChanged && !reduceMotion)
    }

    private func statusText(summary: AcpmuxSessionSummary?) -> (String, NSColor) {
        switch model.connectionState {
        case .connecting:
            return (String(localized: "acpmuxChat.status.connectingShort", defaultValue: "Connecting"), theme.tertiaryText)
        case .failed:
            return (String(localized: "acpmuxChat.status.offline", defaultValue: "Offline"), theme.danger)
        case .connected:
            break
        }
        if model.pendingPermission != nil {
            return (String(localized: "acpmuxChat.status.waiting", defaultValue: "Waiting for approval"), theme.accent)
        }
        if model.isWorking {
            return (String(localized: "acpmuxChat.status.working", defaultValue: "Working"), theme.accent)
        }
        switch summary?.status {
        case "disconnected", "closed":
            return (String(localized: "acpmuxChat.status.stopped", defaultValue: "Agent stopped"), theme.tertiaryText)
        case nil:
            return ("", theme.tertiaryText)
        default:
            return (String(localized: "acpmuxChat.status.ready", defaultValue: "Ready"), theme.success)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        relayout(animated: false)
    }

    private func relayout(animated: Bool) {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: AcpmuxChatHeaderView.height)
        let margin: CGFloat = 12
        let composerHeight = composer.preferredHeight
        let composerFrame = CGRect(x: margin, y: height - 10 - composerHeight, width: width - 2 * margin, height: composerHeight)
        let queueHeight = queueStrip.preferredHeight
        let queueFrame = CGRect(x: margin, y: composerFrame.minY - (queueHeight > 0 ? queueHeight + 6 : 0), width: width - 2 * margin, height: queueHeight)
        let cardHeight = showsPermissionCard ? permissionCard.preferredHeight : 0
        let cardFrame = CGRect(x: margin, y: queueFrame.minY - (showsPermissionCard ? cardHeight + 8 : 0), width: width - 2 * margin, height: cardHeight)
        let transcriptFrame = CGRect(x: 0, y: header.frame.maxY, width: width, height: max(0, cardFrame.minY - header.frame.maxY - 4))
        let pillSize = jumpPill.frame.size
        let pillFrame = CGRect(x: (width - pillSize.width) / 2, y: transcriptFrame.maxY - pillSize.height - 10,
                               width: pillSize.width, height: pillSize.height)
        let apply = {
            self.composer.frame = composerFrame
            self.queueStrip.frame = queueFrame
            self.transcript.frame = transcriptFrame
            if self.showsPermissionCard {
                self.permissionCard.frame = cardFrame
            } else {
                // Slide out below its resting place as it fades.
                self.permissionCard.frame = CGRect(x: margin, y: queueFrame.minY, width: width - 2 * margin, height: self.permissionCard.frame.height)
            }
            self.permissionCard.alphaValue = self.showsPermissionCard ? 1 : 0
            self.jumpPill.frame = pillFrame
        }
        if animated {
            if showsPermissionCard, permissionCard.frame.height == 0 {
                permissionCard.frame = CGRect(x: margin, y: queueFrame.minY, width: width - 2 * margin, height: permissionCard.preferredHeight)
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.04)
                context.allowsImplicitAnimation = true
                apply()
                self.layoutSubtreeIfNeeded()
            }
        } else {
            apply()
        }
        statusLabel.frame = CGRect(x: 24, y: transcriptFrame.midY - 20, width: max(0, width - 48), height: 40)
        if transcript.isPinnedToBottom { transcript.scrollToBottom(animated: false) }
    }

    private func updateJumpPill(pinned: Bool, unread: Int) {
        let show = !pinned
        jumpPill.update(unread: unread, theme: theme)
        relayout(animated: false)
        guard show != showsJumpPill else { return }
        showsJumpPill = show
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.2
            jumpPill.animator().alphaValue = show ? 1 : 0
        }
    }

    @objc private func jumpPressed() {
        transcript.jumpToLatest()
    }

    // MARK: - Sending

    private func submit(_ text: String) {
        let startFrame = convert(composer.textFrame, from: composer)
        composer.clear()
        guard let rowID = model.send(text) else {
            transcript.jumpToLatest()
            return
        }
        guard !reduceMotion, window != nil else {
            transcript.jumpToLatest()
            return
        }
        // One transaction: insert the hidden row, scroll it into its final slot, measure,
        // and add the overlay, so no frame shows the cell before the overlay covers it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        transcript.setRowHidden(rowID, hidden: true)
        transcript.flush(animateScroll: false)
        transcript.jumpToLatest(animated: false)
        transcript.layoutSubtreeIfNeeded()
        guard let target = transcript.bubbleFrame(of: rowID).map({ convert($0, from: transcript) }) else {
            transcript.setRowHidden(rowID, hidden: false)
            return
        }
        let horizontal = AcpmuxRowLayoutEngine.bubbleHorizontalPadding
        let vertical = AcpmuxRowLayoutEngine.bubbleVerticalPadding
        let overlay = AcpmuxMorphBubbleView(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            theme: theme,
            from: startFrame,
            textWidth: max(1, target.width - 2 * horizontal)
        )
        addSubview(overlay)
        activeMorph = (rowID, overlay, target)
        overlay.morph(to: target, textOrigin: CGPoint(x: horizontal, y: vertical)) { [weak self, weak overlay] in
            self?.finishMorph(overlay)
        }
    }

    private var activeMorph: (rowID: String, overlay: AcpmuxMorphBubbleView, target: CGRect)?

    /// Reveals the real cell and drops the overlay in one transaction: no flicker frame.
    private func finishMorph(_ overlay: AcpmuxMorphBubbleView?) {
        guard let morph = activeMorph, overlay == nil || morph.overlay === overlay else { return }
        activeMorph = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transcript.setRowHidden(morph.rowID, hidden: false)
        morph.overlay.layer?.removeAllAnimations()
        morph.overlay.removeFromSuperview()
        CATransaction.commit()
    }

    /// Ends the morph early when rows arriving mid-flight move its slot, so the overlay
    /// never finishes at a stale position.
    private func checkMorphTarget() {
        guard let morph = activeMorph,
              let current = transcript.bubbleFrame(of: morph.rowID).map({ convert($0, from: transcript) }) else { return }
        if abs(current.minY - morph.target.minY) > 0.5 || abs(current.minX - morph.target.minX) > 0.5 {
            finishMorph(nil)
        }
    }

    // MARK: - Menus

    @objc private func showSessionMenu() {
        let menu = NSMenu()
        for session in model.sessions.prefix(40) {
            let item = NSMenuItem(title: session.displayTitle, action: #selector(selectSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.sessionId
            item.state = session.sessionId == model.sessionId ? .on : .off
            if let harness = session.harness {
                item.toolTip = harness
            }
            menu.addItem(item)
        }
        if !model.sessions.isEmpty { menu.addItem(.separator()) }
        let newItem = NSMenuItem(
            title: String(localized: "acpmuxChat.menu.newSession", defaultValue: "New Session"),
            action: #selector(newSession(_:)),
            keyEquivalent: ""
        )
        newItem.target = self
        menu.addItem(newItem)
        let newWith = NSMenuItem(title: String(localized: "acpmuxChat.menu.newSessionWith", defaultValue: "New Session With"), action: nil, keyEquivalent: "")
        newWith.submenu = harnessMenu()
        menu.addItem(newWith)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: header.pickerButton.bounds.height + 4), in: header.pickerButton)
    }

    private func harnessMenu() -> NSMenu {
        let menu = NSMenu()
        for harness in model.catalog.harnesses {
            let item = NSMenuItem(title: harness.name, action: #selector(chooseHarness(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = harness.name
            item.isEnabled = harness.unavailableReason == nil
            item.toolTip = harness.unavailableReason
            menu.addItem(item)
        }
        return menu
    }

    private func modelMenu(_ models: [AcpmuxHarnessCatalog.Model], current: String?) -> NSMenu {
        let menu = NSMenu()
        for option in models {
            let item = NSMenuItem(title: option.name ?? option.id, action: #selector(chooseModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = option.id == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { await model.select(sessionId: id) }
    }

    @objc private func newSession(_ sender: NSMenuItem) {
        Task { await model.createSession(harness: model.newSessionHarness ?? model.catalog.defaultHarness) }
    }

    @objc private func chooseHarness(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        model.newSessionHarness = name
        if model.sessionId != nil {
            Task { await model.createSession(harness: name) }
        } else {
            renderChrome()
        }
    }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setModel(id)
    }
}
