public import AppKit
public import CmuxHomeCore
import UniformTypeIdentifiers

/// Drop, paste and the file picker all end in `attach`: inputs the allow
/// list refuses get a notice, the rest are prepared by the data side in
/// arrival order and land in the field as MessagesLab's chips. A drop's
/// promised files (`HomePromisedFiles`) take their place in that order once
/// their app wrote them; the notice says they are coming meanwhile.
///
/// This view is Home's drop target for the whole pane: drags over the
/// transcript, the header and the empty states reach it (MessagesLab's views
/// register no drag types), the field reports its own drags here
/// (`onAttachmentDrop*`), and Home's conversation list forwards its drags to
/// the shown conversation's view. Each shows the drop highlight while a drag
/// the composer takes is over it.
extension HomeNativeTranscriptView {
    /// What the drop target registers (Home's conversation list registers the same).
    static var attachmentDragTypes: [NSPasteboard.PasteboardType] { HomeAttachmentIntake.dragTypes }

    /// The MessagesLab host's entry points ("+", paste, drop) and the
    /// binding's callbacks reach this view's intake and notice.
    func connectAttachments() {
        transcript.onPickAttachments = { [weak self] in self?.pickFiles() }
        transcript.onAttachmentPasteboard = { [weak self] board in self?.handlePaste(board) ?? false }
        // The words a taken paste carries beside its attachments: the field inserts them.
        transcript.attachmentPasteText = { board in HomeAttachmentIntake.textBeside(board) }
        transcript.acceptsAttachmentDrag = { [weak self] board in
            self?.attachmentPreparer != nil && HomeAttachmentIntake.offers(board)
        }
        transcript.onAttachmentDrop = { [weak self] board in
            guard let self else { return false }
            return self.handleDrop(self.drop.contents(board))
        }
        transcript.acceptsAttachmentDrop = { [weak self] board in
            guard let self, self.attachmentPreparer != nil else { return false }
            return HomeAttachmentIntake.offers(self.drop.contents(board), dragging: true)
        }
        transcript.onAttachmentDropTarget = { [weak self] targeted in self?.drop.highlight.show(targeted) }
        drop.install(in: self)
        transcript.onAttachmentRefusal = { [weak self] refusal in self?.showAttachmentRefusal(refusal) }
        transcript.onDraftTextChange = { [weak self] in self?.draftTextChanged() }
        transcript.fetchAttachment = binding.fetchAttachment
        transcript.onCancelSend = { [weak binding] key in binding?.cancelSend(key) ?? false }
        transcript.onRefusal = { [weak self] _, rejection in self?.showRefusal(rejection) }
        binding.onRefusal = { [weak self] _, rejection in self?.showRefusal(rejection) }
        binding.onSendNotDelivered = { [weak self] _, rejection in self?.showNotDelivered(rejection) }
        binding.onUnanswered = { [weak self] intent in self?.showUnanswered(intent) }
        registerForDraggedTypes(HomeAttachmentIntake.dragTypes)
    }

    /// Files, promised files or pictures dropped anywhere on the pane or the field. A drop with
    /// file promises (and no file URL) asks their app for the files now and attaches them when
    /// they are written; the drag's own picture bytes stand in when no file comes.
    @discardableResult
    func handleDrop(_ board: any HomePasteboardContents) -> Bool {
        guard attachmentPreparer != nil else { return false }
        if let promised = HomePromisedFiles(HomeAttachmentIntake.promises(from: board)) {
            // Read now: the drag pasteboard is the next drag's once this one ends.
            attachPromised(promised, standIn: HomeAttachmentIntake.inputs(from: board))
            return true
        }
        return handlePaste(board)
    }

    /// Paste: files and pictures become attachments; text stays text.
    @discardableResult
    func handlePaste(_ board: any HomePasteboardContents) -> Bool {
        guard attachmentPreparer != nil else { return false }
        let inputs = HomeAttachmentIntake.inputs(from: board)
        guard !inputs.isEmpty else { return false }
        attach(inputs)
        return true
    }

    /// The file picker's choice.
    func handlePicked(_ urls: [URL]) {
        guard attachmentPreparer != nil, !urls.isEmpty else { return }
        attach(urls.map { .file($0) })
    }

    /// Opens the file picker as a sheet (the attach button, `home.attachFiles`), in the
    /// click's own turn and from the panel made ahead (`HomeAttachmentPanel`).
    public func pickFiles() {
        guard let window, attachmentPreparer != nil, let attachmentPanel else { return }
        attachmentPanel.present(for: window) { [weak self] urls in
            // Chosen or cancelled, the person goes back to typing in the box.
            defer { self?.transcript.focusPrimaryInputForTyping() }
            guard let urls else { return }
            self?.handlePicked(urls)
        }
    }

    /// Prepares `inputs` after every earlier intake, in order. The type and size checks stat each
    /// file, so they run off the main actor (a click, a paste or a drop returns at once; a file on
    /// a slow volume no longer stalls the window); refusals show as the notice when they are known.
    /// The part limit counts what earlier intakes (a drop's promised files) added.
    func attach(_ inputs: [HomeDraftInput]) {
        guard let preparer = attachmentPreparer else { return }
        let previous = intake
        let keepLocation = self.keepLocation()
        intake = Task { [weak self] in
            await previous?.value
            await self?.checkAndPrepare(inputs, with: preparer, keepLocation: keepLocation)
        }
    }

    /// A drop's promised files, after every earlier intake and in their place in the order. The
    /// notice says they are coming while their app writes them (the main thread never waits for it).
    /// `standIn`: the drag's own picture, read at the drop, for when no file comes.
    func attachPromised(_ promised: HomePromisedFiles, standIn: [HomeDraftInput]) {
        guard let preparer = attachmentPreparer else { return promised.discard() }
        drop.pending += 1
        showNotice(pendingNotice)
        let previous = intake
        let keepLocation = self.keepLocation()
        intake = Task { [weak self] in
            let files = await promised.files.value
            await previous?.value
            defer { promised.discard() }
            guard let self else { return }
            self.drop.pending -= 1
            if self.notice == HomeStrings.attachPending { self.showNotice(self.pendingNotice) }
            // No file came (the app failed or quit): the drag's own picture, if it carried one.
            let inputs = files.isEmpty ? standIn : files.map { HomeDraftInput.file($0) }
            await self.checkAndPrepare(inputs, with: preparer, keepLocation: keepLocation)
            // A source that wrote nothing, or fewer files than it promised, says so (after the batch's own notice).
            if inputs.isEmpty || files.count < promised.expected && standIn.isEmpty { self.showNotice(HomeStrings.attachFailed) }
        }
    }

    /// The notice while a drop's files are on their way; nil when none is.
    var pendingNotice: String? { drop.pending > 0 ? HomeStrings.attachPending : nil }

    /// Checks `inputs` off the main actor, admits what fits, and prepares it into the draft in order.
    private func checkAndPrepare(_ inputs: [HomeDraftInput], with preparer: any HomeAttachmentPreparing, keepLocation: Bool) async {
        guard !inputs.isEmpty else { return }
        // task-owner: awaited here; the stats end with it
        let problems = await Task.detached(priority: .userInitiated) { inputs.map(HomeComposerCheck.problem(for:)) }.value
        guard !Task.isCancelled else { return }
        for input in admit(inputs, problems) {
            let prepared: LocalAttachment
            do {
                prepared = try await Self.prepare(input, with: preparer, keepLocation: keepLocation)
            } catch let refusal as HomeAttachmentError {
                showNotice(HomeStrings.attachmentRefusal(refusal))
                continue
            } catch {
                showNotice(HomeStrings.attachFailed)
                continue
            }
            guard !Task.isCancelled else { return }
            await transcript.addDraftAttachment(prepared)
        }
    }

    /// The inputs the checks passed that fit the part limit; the first refusal shows as the notice.
    private func admit(_ inputs: [HomeDraftInput], _ problems: [(error: HomeAttachmentError, name: String?)?]) -> [HomeDraftInput] {
        var accepted: [HomeDraftInput] = []
        var refusals: [String] = []
        // Attachments plus the text part fit the owner's part limit.
        var room = CmuxHomeCore.HomeAttachmentPolicy.maxParts - 1 - transcript.draftAttachments.count
        for (input, problem) in zip(inputs, problems) {
            if let problem {
                refusals.append(HomeComposerCheck.notice(problem))
            } else if room <= 0 {
                refusals.append(HomeStrings.attachmentRefusal(.tooManyParts(limit: CmuxHomeCore.HomeAttachmentPolicy.maxParts)))
            } else {
                accepted.append(input)
                room -= 1
            }
        }
        // A clean batch clears an earlier refusal (not "on its way" while a drop's files still come,
        // nor a notice with an action, the mic's).
        if let first = refusals.first { showNotice(first) } else if noticeAction == nil { showNotice(pendingNotice) }
        return accepted
    }

    private static func prepare(_ input: HomeDraftInput, with preparer: any HomeAttachmentPreparing, keepLocation: Bool) async throws
        -> LocalAttachment {
        switch input {
        case .file(let url): try await preparer.prepareAttachment(fileURL: url, keepLocation: keepLocation)
        case .data(let data, let type):
            try await preparer.prepareAttachment(data: data, typeIdentifier: type, keepLocation: keepLocation)
        }
    }

    /// The owner's data side refused a send's attachment before logging it
    /// (`HomeStoreBinding.onAttachmentRefusal`); the draft is back.
    public func showAttachmentRefusal(_ refusal: HomeAttachmentError) {
        showNotice(HomeStrings.attachmentRefusal(refusal))
    }

    /// A send the owner refused after it left the composer (a resumed
    /// upload, a resend after backoff): `HomeStoreBinding.onRefusal`.
    public func showRefusal(_ rejection: HomeRejection) {
        showNotice(HomeStrings.rejection(rejection))
    }

    /// One of my sends was refused after it was logged (its row says "Not
    /// Delivered", `HomeStoreBinding.onSendNotDelivered`): say why.
    public func showNotDelivered(_ rejection: HomeRejection) {
        showNotice(HomeStrings.notDeliveredReason(rejection))
    }

    /// An op (a tapback, a read cursor) ran out of resends unanswered
    /// (`HomeStoreBinding.onUnanswered`): it may not have gone through.
    public func showUnanswered(_ intent: HomeIntent) {
        showNotice(HomeStrings.unanswered)
    }

    /// Returns when every attachment given so far is in the draft (each one copied into the
    /// blob cache, so its source file may go): tests, and design mode's temp files.
    public func attachmentsReady() async {
        while let current = intake {
            await current.value
            if intake == current { return }
        }
    }

    // MARK: Drag and drop

    /// Copy when the composer takes the drag, else none; the highlight follows. Types, file names
    /// and the plain string only, read once per drag (AppKit waits for each drag-over answer):
    /// the picture bytes are read once, on drop.
    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts: Bool
        if let answer = drop.answer, answer.sequence == sender.draggingSequenceNumber {
            accepts = answer.accepts
        } else {
            accepts = attachmentPreparer != nil && HomeAttachmentIntake.offers(drop.contents(sender.draggingPasteboard), dragging: true)
            drop.answer = (sender.draggingSequenceNumber, accepts)
        }
        drop.highlight.show(accepts)
        return accepts ? .copy : []
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        drop.answer = nil
        return dropOperation(sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    // NSView has no `draggingExited:`/`draggingEnded:` of its own: no super call.
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        drop.answer = nil
        drop.highlight.show(false)
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        drop.answer = nil
        drop.highlight.show(false)
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let takes = dropOperation(sender) == .copy
        drop.answer = nil
        drop.highlight.show(false)
        guard takes, handleDrop(drop.contents(sender.draggingPasteboard)) else { return false }
        // A drop aimed at Home (the first-run panel, the margins): type at once.
        transcript.focusPrimaryInputForTyping()
        return true
    }

    /// Automation (DEBUG socket): the draft's attachments (name, type, size), the drops still
    /// on their way, the notice and whether the drop highlight shows.
    public var debugDraftState: (attachments: [(name: String, mimeType: String, bytes: Int)], pending: Int, notice: String?, highlighted: Bool) {
        (transcript.draftAttachments.map { ($0.ref.name, $0.ref.mimeType, $0.ref.byteCount) }, drop.pending, notice, drop.highlight.isShowing)
    }
}

extension HomeNativeTranscriptView {
    /// Every key typed into the composer ends here (`ChatController.textDidChange`, vendored MessagesLab, carries
    /// the other home-key marker): a notice the person typed past goes. Keep it O(1): no transcript or row work.
    func draftTextChanged() { // perf-hot: 0.1ms home-key (every key typed into the Home composer)
        guard notice != nil, !transcript.draftText.isEmpty else { return }
        showNotice(nil)
    }
}
