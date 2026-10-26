import AppKit
import CmuxChief
import CmuxHomeCore
import CmuxHomeRender
import CmuxSettings
import MessagesLabHome
import Observation
import UniformTypeIdentifiers

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
    /// "Working · 12s" above the field while a turn runs (``ChiefWorkingStatusView``).
    private let workingStatus = ChiefWorkingStatusView()
    private let unavailableLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsPanel = ChiefSettingsPanel()
    /// Mirrors this conversation in the movable right Dock.
    private let dockButton = NSButton()
    /// "Opus 5.5 · Medium" under the name pill, and the pill's tooltip (``ChiefSettingsBrainHint``).
    private let brainHint = ChiefSettingsBrainHint()
    /// Chief memory: reports saved notes to the owner, whose "Chief will remember … · Undo"
    /// row is a transcript row (``ChiefMemoryNoticeRelay``).
    private lazy var memoryNotice = ChiefMemoryNoticeRelay(conversation: conversation) { [weak self] in
        guard let self else { return false }
        return self.window != nil && self.isActive && !self.isHiddenOrHasHiddenAncestor
    }
    private var notice: String?
    private var settingsOpen = false
    /// The first page is not in yet: the first-run panel waits so a
    /// conversation with history never flashes it.
    private var holdsFirstRun = true
    private var stopped = false
    // SAFETY: written only on the main actor; `deinit` reads it once no other
    // reference exists, and NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    // SAFETY: written only on the main actor; `deinit` reads it once no other
    // reference exists, and NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var windowObservers: [any NSObjectProtocol] = []
    // task-owner: the chain of attachment preparations, in arrival order; cancelled by stop()
    private var intake: Task<Void, Never>?
    // task-owner: ends when the conversation's first page is in; cancelled by stop()
    private var firstPage: Task<Void, Never>?
    private var theme = ChiefTheme.current()
    private var profile = ChiefProfile()
    /// What the header avatar shows now; nil after the profile was re-read.
    private var shownAvatar: (kind: ChiefAvatarArtwork.Kind, isDark: Bool)?

    /// Whether the host shows this view now (Home selected, the tab visible).
    /// Hidden views report not visible, so MessagesLab defers read receipts.
    var isActive = true { didSet { if isActive != oldValue { windowStateChanged() } } }

    /// Whether the host hides the workspace list while this view shows (Home
    /// selected): the first-run hint then names the way back, not ⌃1…9.
    var hidesWorkspaces = false { didSet { firstRun.hidesWorkspaces = hidesWorkspaces } }

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
        dockButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: ChiefStrings.openInDock)
        dockButton.imagePosition = .imageOnly
        dockButton.bezelStyle = .texturedRounded
        dockButton.isBordered = false
        dockButton.isTransparent = true
        dockButton.target = self
        dockButton.action = #selector(openInDock)
        dockButton.setAccessibilityLabel(ChiefStrings.openInDock)
        dockButton.toolTip = ChiefStrings.openInDock
        dockButton.setAccessibilityIdentifier("ChiefOpenInDock")
        addSubview(dockButton)
        addSubview(firstRun)
        firstRun.isHidden = true
        noticeLabel.isHidden = true
        noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.alignment = .center
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.isSelectable = false
        addSubview(noticeLabel)
        addSubview(workingStatus)
        unavailableLabel.alignment = .center
        unavailableLabel.isHidden = transcript != nil
        unavailableLabel.stringValue = service.startFailure ?? ChiefStrings.unavailable
        addSubview(unavailableLabel)
        settingsPanel.isHidden = true
        brainHint.label.isHidden = true
        if transcript != nil { addSubview(brainHint.label) }
        addSubview(settingsPanel)
        // Chief memory: saved notes become transcript rows (ChiefMemoryNoticeRelay).
        if transcript != nil { _ = memoryNotice }
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

    // Not an isolated deinit (Swift 6.0 has none). A view freed without
    // `stop()` still stops its parts, so the projection stops streaming: at
    // once on the main thread, else in one hop that carries the parts (never
    // `self`) to the main actor. The memory notice removes its own observer.
    deinit {
        for observer in observers + windowObservers { NotificationCenter.default.removeObserver(observer) }
        guard !stopped else { return }
        // Built here, not through `stopParts`: a deinit may read these stored properties.
        let parts = StopParts(key: ObjectIdentifier(self), tasks: [intake, firstPage].compactMap { $0 },
                              workingStatus: workingStatus, settingsPanel: settingsPanel,
                              transcript: transcript, binding: binding)
        if Thread.isMainThread {
            MainActor.assumeIsolated { parts.stop() } // main-proof: this branch runs only on the main thread
        } else {
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in parts.stop() }
        }
    }

    /// Stops forwarding and closes the conversation on the store. Once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        stopParts.stop()
        memoryNotice.stop()
    }

    /// What `stop()` stops, as values `deinit` can hand to the main actor.
    private struct StopParts: Sendable {
        let key: ObjectIdentifier
        let tasks: [Task<Void, Never>]
        let workingStatus: ChiefWorkingStatusView
        let settingsPanel: ChiefSettingsPanel
        let transcript: MessagesLabHomeView?
        let binding: HomeStoreBinding?

        @MainActor func stop() {
            ChiefService.shared.setTranscript(key, showing: nil)
            for task in tasks { task.cancel() }
            workingStatus.stop()
            settingsPanel.stop()
            transcript?.stop()
            binding?.stop()
        }
    }

    private var stopParts: StopParts {
        StopParts(key: ObjectIdentifier(self), tasks: [intake, firstPage].compactMap { $0 },
                  workingStatus: workingStatus, settingsPanel: settingsPanel,
                  transcript: transcript, binding: binding)
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
        brainHint.onToolTip = { [weak transcript] toolTip in transcript?.setNamePillToolTip(toolTip) }
        transcript.onNamePill = { [weak self] in self?.toggleSettings() }
        transcript.onStop = { [weak self] in self?.stopChief() }
        transcript.onAppLink = { url in
            if let handler = ChiefService.shared.onAppLink { handler(url) } else { NSWorkspace.shared.open(url) }
        }
        transcript.onSummaryChange = { [weak self] _ in
            self?.updateFirstRun()
            self?.updateBrainHint()
        }
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
        transcript.onOpenCloudWorkspace = { [weak self] machine, workspace in self?.openCloudWorkspace(machine, workspace) }
        transcript.onOpenCloudDesktop = { [weak self] machine in self?.openCloudDesktop(machine) }
        // A turn's end, a failure or an approval card drops the typing dots at once (no fading ghost).
        transcript.typingLeavesAtOnce = true
        let id = conversation
        transcript.onRetryLastTurn = { completion in
            // task-owner: one retry; ends with the owner's answer
            Task { @MainActor in completion(await ChiefService.shared.retryLastTurn(id)) }
        }
        transcript.onUndoMemory = { fact, completion in
            // task-owner: one undo; ends when the note is forgotten and its row updated
            Task { @MainActor in completion(await ChiefService.shared.undoMemory(fact, in: id)) }
        }
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
        settingsPanel.onChoosePicture = { [weak self] in self?.pickAvatarPicture() }
        settingsPanel.onRemovePicture = { [weak self] in self?.updateProfile { $0.picture = nil } }
        settingsPanel.onNewConversation = { [weak self] in self?.newConversation() }
        settingsPanel.onName = { name in ChiefService.shared.setChiefName(name) }
        settingsPanel.onShowTranscriptLog = { [weak self] in
            guard let self else { return }
            ChiefService.shared.revealTranscriptLog(self.conversation)
        }
        settingsPanel.conversation = conversation
    }

    /// The brain hint shows under the pill of a Chief conversation only.
    private func updateBrainHint() {
        guard let transcript else { return }
        let hidden = transcript.conversationSummary?.kind(me: ChiefService.shared.me) != .chief
        if brainHint.label.isHidden != hidden {
            brainHint.label.isHidden = hidden
            needsLayout = true
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
            let start = ChiefService.shared.turnStart(id)
            let wasShown = workingStatus.isShown
            // While an approval waits the transcript's own last row says "Waiting for you"
            // (HomeProjection.applyApprovalWait), so this line steps aside.
            workingStatus.show(since: ChiefService.shared.hasPendingApproval(id) ? nil : start)
            if workingStatus.isShown != wasShown { needsLayout = true }
            // The newest row clears the working line by `workingLineRoom` more (v3f b1: it sat 4 pt under the bubble).
            transcript.transcriptBottomInset = workingStatus.isShown ? Self.workingLineRoom : 0
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
            ChiefService.shared.setTranscript(self, showing: nil)
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

    /// Visible to the user: the window is key and on screen, the host shows
    /// this view, and nothing hides it. Only then do replies count as read
    /// (MessagesLab advances the read cursor) and leave the unread count.
    private func windowStateChanged() {
        guard let transcript, !stopped else { return }
        let onScreen = window.map { $0.isKeyWindow && $0.occlusionState.contains(.visible) } ?? false
        let visible = onScreen && isActive && !isHiddenOrHasHiddenAncestor
        transcript.isVisibleToUser = visible
        ChiefService.shared.setTranscript(self, showing: visible ? conversation : nil)
    }

    // MARK: Theme

    /// The header band's strongest alpha: 15 pt text under it falls below 3:1 against the band.
    static let headerBandAlpha: CGFloat = 0.94
    /// The room the transcript adds under its newest row while "Working · Ns" shows above the field.
    static let workingLineRoom: CGFloat = 6
    /// How far the header band reaches: solid past the model line under the pill (its 16 pt line),
    /// then an 18 pt fade (MessagesLab's `HostView.solidFadeLength`).
    static var headerBandExtent: CGFloat { ChiefSettingsBrainHint.top + 16 + 18 }

    private func applyTheme() {
        let theme = ChiefTheme.current()
        self.theme = theme
        // The whole surface (header pill, buttons, chips, panels) resolves in the
        // terminal theme's light or dark, not the app's (ChiefTheme.appearance).
        // Compared by name: setting it re-enters through viewDidChangeEffectiveAppearance.
        if appearance?.name != theme.appearance?.name { appearance = theme.appearance }
        if let transcript {
            let palettes = theme.palettes()
            transcript.applyTheme(active: palettes.active, inactive: palettes.inactive, measuredAccent: true)
            // The pill's glass and the band in the terminal theme's appearance too, not the app's.
            transcript.setHeaderAppearance(theme.appearance)
            transcript.setHeaderPillBacking(theme.opaqueBackground.withAlphaComponent(0.72))
            // The header's band: shown whenever a row lies under the avatar, pill and model line (not only
            // on hover), nearly opaque so bubble text under it stays out of the way, and reaching below the
            // model line (ChiefSettingsBrainHint).
            transcript.setHeaderFade(color: theme.opaqueBackground, maxAlpha: Self.headerBandAlpha, extent: Self.headerBandExtent,
                                     revealsWhenScrolled: true) { shown in
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : (shown ? 0.2 : 0.3)
            }
            // The same band under the field over rows scrolled beneath it (v3f k1: a bubble showed through the composer).
            transcript.setFooterFade(color: theme.opaqueBackground, maxAlpha: Self.headerBandAlpha)
        }
        applyAvatar()
        firstRun.apply(theme)
        settingsPanel.apply(theme)
        brainHint.apply(theme)
        noticeLabel.textColor = theme.textSecondary
        workingStatus.apply(theme)
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
        profile = ChiefProfile.load(from: home)
        // A new picture keeps its file name: draw again.
        shownAvatar = nil
        applyAvatar()
        settingsPanel.refresh(avatar: profile.avatar ?? "", hasPicture: profile.pictureURL(in: home) != nil,
                              name: profile.name ?? "")
    }

    /// The header avatar: the one Chief avatar the list and the sidebar's Home
    /// row draw too (``ChiefAvatarArtwork``), at the header's 40 pt.
    private func applyAvatar() {
        guard let transcript else { return }
        let kind = ChiefAvatarArtwork.kind(profile, home: ChiefService.shared.home)
        if let shown = shownAvatar, shown.kind == kind, shown.isDark == theme.isDark { return }
        shownAvatar = (kind, theme.isDark)
        transcript.avatarText = profile.avatar
        transcript.avatarPicture = ChiefAvatarArtwork.image(kind, diameter: 40, isDark: theme.isDark)
    }

    private func setAvatar(_ text: String?) {
        updateProfile { $0.avatar = text }
    }

    /// Opens the image picker for the avatar picture (a sheet on this window).
    private func pickAvatarPicture() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = ChiefStrings.settingsAvatarPickerPrompt
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { // main-proof: the sheet's completion runs on the main thread
                guard let self, let home = ChiefService.shared.home else { return }
                do {
                    let name = try ChiefProfile.importPicture(from: url, into: home)
                    self.updateProfile { $0.picture = name }
                } catch {
                    self.showNotice(ChiefStrings.settingsAvatarPictureFailed)
                }
            }
        }
    }

    /// Changes the saved profile, then every Chief view re-reads it.
    private func updateProfile(_ change: (inout ChiefProfile) -> Void) {
        guard let home = ChiefService.shared.home else { return }
        var updated = ChiefProfile.load(from: home)
        change(&updated)
        try? updated.save(to: home)
        loadProfile()
        NotificationCenter.default.post(name: ChiefProfile.didChange, object: nil)
    }

    // MARK: Stop

    private func stopChief() {
        let id = conversation
        // task-owner: one stop; ends with the owner's answer
        Task { await ChiefService.shared.stop(id) }
    }

    @objc private func openInDock() {
        _ = AppDelegate.shared?.openChiefInRightDock(
            conversationID: conversation,
            preferredWindow: window
        )
    }

    // MARK: Settings panel

    /// The name pill: the settings panel slides in from the right while the
    /// transcript narrows, or out again. Only over a Chief conversation.
    func toggleSettings() {
        let open = !settingsOpen
        settingsOpen = open
        if open {
            if let home = ChiefService.shared.home {
                let current = ChiefProfile.load(from: home)
                settingsPanel.refresh(avatar: current.avatar ?? "", hasPicture: current.pictureURL(in: home) != nil,
                                      name: current.name ?? "")
            }
            settingsPanel.isHidden = false
            settingsPanel.frame = panelFrame(open: false)
        }
        let animated = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.28 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Only the three frames below animate. Implicit animation also animated the transcript's own
            // layout inside the group (its clip view's scroll origin among them): the clip then moved on its
            // own after the transcript had pinned it, the move read as the person's scroll and dropped the
            // pin, and later turns landed below the composer (v3f light-k).
            context.allowsImplicitAnimation = false
            settingsPanel.animator().frame = panelFrame(open: open)
            transcript?.animator().frame = transcriptFrame(open: open)
            brainHint.label.animator().frame = brainHint.frame(in: transcriptFrame(open: open))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { // main-proof: AppKit runs animation completions on the main thread
                guard let self, !self.settingsOpen else { return }
                self.settingsPanel.isHidden = true
            }
        })
    }

    #if DEBUG
    /// `chief.debug open-settings` / `close-settings`: the name pill's slide,
    /// only when it would change something. Returns whether the panel is open.
    func debugSetSettings(open: Bool) -> Bool {
        if open != settingsOpen { toggleSettings() }
        return settingsOpen
    }

    /// `chief.debug expand-tools`: presses the newest collapsed "Ran N
    /// commands" run on screen, as a click does. Returns whether one expanded.
    func debugExpandNewestToolRun() -> Bool {
        var runs: [NSView] = []
        func collect(_ view: NSView) {
            if view.accessibilityIdentifier() == "ChiefToolRow", view.accessibilityRole() == .button,
               !view.isAccessibilityExpanded(), !view.isHiddenOrHasHiddenAncestor {
                runs.append(view)
            }
            view.subviews.forEach(collect)
        }
        collect(self)
        // The newest is the lowest on screen (window coordinates grow upward).
        let newest = runs.min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        return newest?.accessibilityPerformPress() ?? false
    }
    #endif

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
        dockButton.frame = CGRect(x: max(8, bounds.maxX - 42), y: 12, width: 28, height: 28)
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
            brainHint.layout(in: place)
        }
        if !settingsPanel.isHidden { settingsPanel.frame = panelFrame(open: settingsOpen) }
        let inset: CGFloat = 24
        let width = max(0, bounds.width - 2 * inset)
        unavailableLabel.preferredMaxLayoutWidth = width
        let height = ceil(unavailableLabel.intrinsicContentSize.height)
        unavailableLabel.frame = CGRect(x: inset, y: (bounds.height - height) / 2, width: width, height: height)
        layoutWorkingStatus()
        layoutNotice()
    }

    /// The working line sits centered right above the field.
    private func layoutWorkingStatus() {
        guard let transcript else { return }
        let height = ceil(workingStatus.intrinsicContentSize.height)
        workingStatus.frame = CGRect(x: 16, y: transcript.fieldTop - height - 6,
                                     width: max(0, transcript.frame.width - 32), height: height)
    }

    private func layoutNotice() {
        guard notice != nil, let transcript else { return }
        let width = max(0, transcript.frame.width - 32)
        noticeLabel.preferredMaxLayoutWidth = width
        let height = ceil(noticeLabel.intrinsicContentSize.height)
        // Above the working line while it shows.
        let bottom = workingStatus.isShown ? workingStatus.frame.minY - 2 : transcript.fieldTop - 8
        noticeLabel.frame = CGRect(x: 16, y: bottom - height, width: width, height: height)
    }

    /// Shows (or with nil clears) the notice above the field; VoiceOver hears it.
    /// A Cloud result card's Open Workspace: the `cmux vm workspace open` path, focused
    /// (the user asked to see it).
    private func openCloudWorkspace(_ machine: String, _ workspace: String) {
        // task-owner: one open; ends when the workspace is projected or fails
        Task { @MainActor [weak self] in
            do {
                try await TerminalController.openRemoteWorkspace(workspace, machine: machine, focus: true)
            } catch {
                self?.showNotice(ChiefStrings.cloudOpenFailed(machine))
            }
        }
    }

    /// A Cloud result card's Open Desktop: use the same bundled CLI path as the Cloud menu,
    /// leaving the display in cmux for the user to inspect or operate.
    private func openCloudDesktop(_ machine: String) {
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let started = CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: window,
            arguments: ["vm", "desktop", machine],
            presentsFailureAlert: false,
            onCompletion: { [weak self] completion in
                guard !completion.succeeded else { return }
                self?.showNotice(ChiefStrings.cloudDesktopOpenFailed(machine))
            }
        )
        if !started { showNotice(ChiefStrings.cloudDesktopOpenFailed(machine)) }
    }

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
