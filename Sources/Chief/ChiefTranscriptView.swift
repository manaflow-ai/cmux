import AppKit
import CmuxChief
import CmuxHomeCore
import CmuxHomeRender
import MessagesLabHome
import Observation

/// One Chief conversation (cmux-next `HomeHostView` over
/// `HomeNativeTranscriptView`): MessagesLab's native transcript and compose
/// field over ``ChiefService``'s store, themed from the terminal, with the
/// first-run panel while the Chief conversation is empty, the notice above
/// the field, attachments (picker, paste, drop), Stop while Chief works, and
/// the Chief Settings panel the header's name pill slides in from the right.
@MainActor
final class ChiefTranscriptView: NSView {
    let conversation: ConversationID
    private let transcript: MessagesLabHomeView?
    private let binding: HomeStoreBinding?
    private let store: HomeStore?
    private let firstRun = ChiefFirstRunView()
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let unavailableLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsPanel = ChiefSettingsPanel()
    private var notice: String?
    private var settingsOpen = false
    /// The first page is not in yet: the first-run panel waits so a
    /// conversation with history never flashes it.
    private var holdsFirstRun = true
    private var stopped = false
    private var observers: [any NSObjectProtocol] = []
    private var windowObservers: [any NSObjectProtocol] = []
    // task-owner: the chain of attachment preparations, in arrival order; cancelled by stop()
    private var intake: Task<Void, Never>?
    // task-owner: ends when the conversation's first page is in; cancelled by stop()
    private var firstPage: Task<Void, Never>?
    private var theme = ChiefTheme.current()

    /// Whether the host shows this view now (Home selected, the tab visible).
    /// Hidden views report not visible, so MessagesLab defers read receipts.
    var isActive = true { didSet { if isActive != oldValue { windowStateChanged() } } }

    /// - Parameter conversation: The conversation to show; nil shows the default Chief's.
    init(conversation: ConversationID? = nil) {
        let service = ChiefService.shared
        let id = conversation ?? service.defaultConversationID
        self.conversation = id
        let store = service.store
        self.store = store
        if let store {
            transcript = MessagesLabHomeView(store: store, conversation: id, me: service.me, wake: ChiefWakeScheduler())
            // One binding per shown conversation: it opens the conversation now; stop() closes it once.
            binding = HomeStoreBinding(store: store, conversation: id)
        } else {
            transcript = nil
            binding = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        // The settings panel slides in from beyond the right edge.
        clipsToBounds = true
        if let transcript { addSubview(transcript) }
        addSubview(firstRun)
        firstRun.isHidden = true
        noticeLabel.isHidden = true
        noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.alignment = .center
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.isSelectable = false
        addSubview(noticeLabel)
        unavailableLabel.alignment = .center
        unavailableLabel.isHidden = transcript != nil
        unavailableLabel.stringValue = service.startFailure ?? ChiefStrings.unavailable
        addSubview(unavailableLabel)
        settingsPanel.isHidden = true
        addSubview(settingsPanel)
        connectTranscript()
        connectFirstRun()
        connectSettings()
        observeService()
        observeTheme()
        applyTheme()
        if let binding {
            firstPage = Task { [weak self] in
                await binding.opened()
                self?.holdsFirstRun = false
                self?.updateFirstRun()
            }
        }
        loadProfile()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // Not an isolated deinit (Swift 6.0 has none): the main-thread check guards the hop.
    deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for observer in observers + windowObservers { NotificationCenter.default.removeObserver(observer) }
            stop()
        }
    }

    /// Stops forwarding and closes the conversation on the store. Once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        intake?.cancel()
        firstPage?.cancel()
        transcript?.stop()
        binding?.stop()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(primaryInput) ?? false
    }

    /// The message box's text view (the view hosts focus).
    var primaryInput: NSView { transcript?.primaryInput ?? self }

    /// Puts the keyboard in the message box.
    func focusComposer() {
        guard let window else { return }
        window.makeFirstResponder(primaryInput)
    }

    // MARK: Wiring

    private func connectTranscript() {
        guard let transcript, let binding else { return }
        transcript.setNamePillHelp(ChiefStrings.settingsPillHelp)
        transcript.onNamePill = { [weak self] in self?.toggleSettings() }
        transcript.onStop = { [weak self] in self?.stopChief() }
        transcript.onAppLink = { url in
            if let handler = ChiefService.shared.onAppLink { handler(url) } else { NSWorkspace.shared.open(url) }
        }
        transcript.onSummaryChange = { [weak self] _ in self?.updateFirstRun() }
        transcript.onRowsChange = { [weak self] in self?.updateFirstRun() }
        transcript.onPickAttachments = { [weak self] in self?.pickFiles() }
        transcript.onAttachmentPasteboard = { [weak self] board in self?.handleDrop(board) ?? false }
        transcript.acceptsAttachmentDrag = { board in ChiefAttachmentIntake.offers(board) }
        transcript.onAttachmentRefusal = { [weak self] refusal in self?.showNotice(ChiefStrings.attachmentRefusal(refusal)) }
        transcript.onDraftTextChange = { [weak self] in
            guard let self, self.notice != nil, !(self.transcript?.draftText.isEmpty ?? true) else { return }
            self.showNotice(nil)
        }
        transcript.fetchAttachment = binding.fetchAttachment
        transcript.onCancelSend = { [weak binding] key in binding?.cancelSend(key) ?? false }
        transcript.onRefusal = { [weak self] _, rejection in self?.showNotice(ChiefStrings.rejection(rejection)) }
        binding.onRefusal = { [weak self] _, rejection in self?.showNotice(ChiefStrings.rejection(rejection)) }
        binding.onSendNotDelivered = { [weak self] _, rejection in self?.showNotice(ChiefStrings.rejection(rejection)) }
        binding.onAttachmentRefusal = { [weak self] _, refusal in self?.showNotice(ChiefStrings.attachmentRefusal(refusal)) }
        binding.onUnanswered = { [weak self] _ in self?.showNotice(ChiefStrings.unanswered) }
        registerForDraggedTypes(ChiefAttachmentIntake.dragTypes)
    }

    private func connectFirstRun() {
        firstRun.onPrompt = { [weak self] prompt in self?.runStarter(prompt) }
        firstRun.onAction = { action in ChiefService.shared.onFirstRunAction?(action) }
        firstRun.setShowsActions(ChiefService.shared.onFirstRunAction != nil)
    }

    private func connectSettings() {
        settingsPanel.onAvatar = { [weak self] text in self?.setAvatar(text) }
        settingsPanel.onNewConversation = { [weak self] in self?.newConversation() }
        settingsPanel.onEditMemory = { [weak self] instructions in
            guard let paths = ChiefService.shared.memoryPaths else { return }
            try? ChiefMemory(paths: paths).ensureDefaults()
            ChiefMemoryEditor.present(title: instructions ? ChiefStrings.memoryInstructionsTitle : ChiefStrings.memoryProfileTitle,
                                      fileURL: instructions ? paths.instructions : paths.person, in: self?.window)
        }
        settingsPanel.onShowMemoryFolder = {
            guard let paths = ChiefService.shared.memoryPaths else { return }
            try? ChiefMemory(paths: paths).ensureDefaults()
            NSWorkspace.shared.activateFileViewerSelecting([paths.person])
        }
    }

    /// A new conversation opens where this one shows: in Home through
    /// ``onOpenConversation``, else the host decides (a Chief tab keeps its conversation).
    var onOpenConversation: ((ConversationID) -> Void)?

    private func newConversation() {
        // task-owner: one op; ends with its reply
        Task { [weak self] in
            do {
                let id = try await ChiefService.shared.createConversation()
                self?.onOpenConversation?(id)
            } catch {
                self?.showNotice(ChiefStrings.newConversationFailed)
            }
        }
    }

    // MARK: Observation

    /// Re-reads the working set, the connection and the conversation's
    /// summary after every change they report (Observation, no polling).
    private func observeService() {
        guard !stopped, let transcript, let store else { return }
        let id = conversation
        withObservationTracking {
            transcript.isWorking = ChiefService.shared.isWorking(id)
            transcript.isSendEnabled = store.isOnline
            _ = store.rows
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeService()
                self?.updateFirstRun()
            }
        }
    }

    private func observeTheme() {
        let center = NotificationCenter.default
        for name in [Notification.Name.ghosttyConfigDidReload, .ghosttyDefaultBackgroundDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTheme() } // main-proof: observer on queue: .main
            })
        }
        observers.append(center.addObserver(forName: ChiefProfile.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadProfile() } // main-proof: observer on queue: .main
        })
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else {
            transcript?.isVisibleToUser = false
            return
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowStateChanged() } // main-proof: observer on queue: .main
            })
        }
        windowStateChanged()
        // A theme change while the view was out of a window.
        applyTheme()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        windowStateChanged()
    }

    override func viewDidHide() {
        super.viewDidHide()
        windowStateChanged()
    }

    private func windowStateChanged() {
        guard let transcript else { return }
        let visible = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
        transcript.isVisibleToUser = visible && isActive && !isHiddenOrHasHiddenAncestor
    }

    // MARK: Theme

    private func applyTheme() {
        let theme = ChiefTheme.current()
        self.theme = theme
        if let transcript {
            let palettes = theme.palettes()
            transcript.applyTheme(active: palettes.active, inactive: palettes.inactive, measuredAccent: true)
            transcript.setHeaderPillBacking(theme.opaqueBackground.withAlphaComponent(0.72))
            transcript.setHeaderFade(color: theme.opaqueBackground, maxAlpha: 0.85) { shown in
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : (shown ? 0.2 : 0.3)
            }
        }
        firstRun.apply(theme)
        settingsPanel.apply(theme)
        noticeLabel.textColor = theme.textSecondary
        unavailableLabel.textColor = theme.textSecondary
        layer?.backgroundColor = transcript == nil ? theme.background.cgColor : nil
    }

    // MARK: First run

    private func updateFirstRun() {
        guard let transcript else { return }
        let isChief = transcript.conversationSummary?.kind(me: ChiefService.shared.me) == .chief
        let hidden = holdsFirstRun || !(transcript.isEmpty && isChief)
        if firstRun.isHidden != hidden {
            firstRun.isHidden = hidden
            needsLayout = true
        }
        firstRun.setShowsActions(ChiefService.shared.onFirstRunAction != nil)
    }

    /// A starter row: fills the box and sends it, or leaves it there to finish.
    private func runStarter(_ prompt: ChiefStarterPrompt) {
        guard let transcript else { return }
        transcript.setDraft(prompt.text)
        if prompt.sends {
            _ = transcript.sendDraft()
        }
        focusComposer()
    }

    // MARK: Header

    private func loadProfile() {
        guard let home = ChiefService.shared.home else { return }
        let profile = ChiefProfile.load(from: home)
        transcript?.avatarText = profile.avatar
        settingsPanel.refresh(avatar: profile.avatar ?? "")
    }

    private func setAvatar(_ text: String?) {
        transcript?.avatarText = text
        guard let home = ChiefService.shared.home else { return }
        try? ChiefProfile(avatar: text).save(to: home)
        NotificationCenter.default.post(name: ChiefProfile.didChange, object: nil)
    }

    // MARK: Stop

    private func stopChief() {
        let id = conversation
        // task-owner: one stop; ends with the owner's answer
        Task { await ChiefService.shared.stop(id) }
    }

    // MARK: Settings panel

    /// The name pill: the settings panel slides in from the right while the
    /// transcript narrows, or out again. Only over a Chief conversation.
    func toggleSettings() {
        let open = !settingsOpen
        settingsOpen = open
        if open {
            settingsPanel.refresh(avatar: ChiefService.shared.home.map { ChiefProfile.load(from: $0).avatar ?? "" })
            settingsPanel.isHidden = false
            settingsPanel.frame = panelFrame(open: false)
        }
        let animated = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.28 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            settingsPanel.animator().frame = panelFrame(open: open)
            transcript?.animator().frame = transcriptFrame(open: open)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { // main-proof: AppKit runs animation completions on the main thread
                guard let self, !self.settingsOpen else { return }
                self.settingsPanel.isHidden = true
            }
        })
    }

    private func panelFrame(open: Bool) -> CGRect {
        let width = ChiefSettingsPanel.width
        return CGRect(x: open ? bounds.maxX - width : bounds.maxX, y: 0, width: width, height: bounds.height)
    }

    private func transcriptFrame(open: Bool) -> CGRect {
        CGRect(x: 0, y: 0, width: max(0, bounds.width - (open ? ChiefSettingsPanel.width : 0)), height: bounds.height)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        if let transcript {
            let place = transcriptFrame(open: settingsOpen)
            if transcript.frame != place {
                let resized = transcript.frame.size != place.size
                transcript.frame = place
                if resized { transcript.layoutSubtreeIfNeeded() }
            }
            let top = transcript.headerHeight
            let panel = CGRect(x: 0, y: top, width: place.width, height: max(0, transcript.fieldTop - top))
            if firstRun.frame != panel { firstRun.frame = panel }
        }
        if !settingsPanel.isHidden { settingsPanel.frame = panelFrame(open: settingsOpen) }
        let inset: CGFloat = 24
        let width = max(0, bounds.width - 2 * inset)
        unavailableLabel.preferredMaxLayoutWidth = width
        let height = ceil(unavailableLabel.intrinsicContentSize.height)
        unavailableLabel.frame = CGRect(x: inset, y: (bounds.height - height) / 2, width: width, height: height)
        layoutNotice()
    }

    private func layoutNotice() {
        guard notice != nil, let transcript else { return }
        let width = max(0, transcript.frame.width - 32)
        noticeLabel.preferredMaxLayoutWidth = width
        let height = ceil(noticeLabel.intrinsicContentSize.height)
        noticeLabel.frame = CGRect(x: 16, y: transcript.fieldTop - height - 8, width: width, height: height)
    }

    /// Shows (or with nil clears) the notice above the field; VoiceOver hears it.
    func showNotice(_ text: String?) {
        guard text != notice else { return }
        notice = text
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = text == nil
        noticeLabel.setAccessibilityLabel(text)
        if let text {
            NSAccessibility.post(element: noticeLabel, notification: .announcementRequested, userInfo: [.announcement: text])
        }
        layoutNotice()
    }

    // MARK: Attachments

    /// Opens the file picker as a sheet (the field's "+").
    func pickFiles() {
        guard let window, transcript != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = ChiefStrings.attachPrompt
        panel.allowedContentTypes = ChiefAttachmentIntake.pickerTypes
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { // main-proof: the sheet's completion runs on the main thread
                self?.attach(urls.map { .file($0) })
            }
        }
    }

    @discardableResult
    private func handleDrop(_ board: NSPasteboard) -> Bool {
        guard transcript != nil else { return false }
        let inputs = ChiefAttachmentIntake.inputs(from: board)
        guard !inputs.isEmpty else { return false }
        attach(inputs)
        return true
    }

    /// Prepares `inputs` after every earlier intake, in order, and adds them to the draft.
    private func attach(_ inputs: [ChiefDraftInput]) {
        guard let store, let transcript else { return }
        var accepted: [ChiefDraftInput] = []
        var refusals: [String] = []
        // Attachments plus the text part fit the owner's part limit.
        var room = HomeAttachmentPolicy.maxParts - 1 - transcript.draftAttachments.count
        for input in inputs {
            if let refusal = ChiefAttachmentIntake.refusal(for: input) {
                refusals.append(refusal)
            } else if room <= 0 {
                refusals.append(ChiefStrings.attachTooMany)
            } else {
                accepted.append(input)
                room -= 1
            }
        }
        showNotice(refusals.first)
        guard !accepted.isEmpty else { return }
        let previous = intake
        intake = Task { [weak self] in
            await previous?.value
            for input in accepted {
                let prepared: LocalAttachment
                do {
                    switch input {
                    case .file(let url): prepared = try await store.prepareAttachment(fileURL: url, keepLocation: false)
                    case .data(let data, let type):
                        prepared = try await store.prepareAttachment(data: data, typeIdentifier: type, keepLocation: false)
                    }
                } catch let refusal as HomeAttachmentError {
                    self?.showNotice(ChiefStrings.attachmentRefusal(refusal))
                    continue
                } catch {
                    self?.showNotice(ChiefStrings.attachFailed)
                    continue
                }
                guard let self, !Task.isCancelled, let transcript = self.transcript else { return }
                await transcript.addDraftAttachment(prepared)
            }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Types only: the bytes are read once, on drop.
        guard transcript != nil, ChiefAttachmentIntake.offers(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        handleDrop(sender.draggingPasteboard)
    }
}
