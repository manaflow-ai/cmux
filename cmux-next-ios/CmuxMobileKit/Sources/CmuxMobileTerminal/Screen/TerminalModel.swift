#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import Observation
import UIKit

/// The terminal screen's state, shared by the UIKit controller (surface,
/// scrolling, keyboard tracking) and the SwiftUI chrome (toolbar, composer,
/// key bar, sheets). The session is the data source.
@MainActor
@Observable
public final class TerminalModel {
    public let session: any TerminalSession
    public let artifactSource: any ArtifactSource

    public internal(set) var title: String
    public internal(set) var programName: String
    /// Alternate screen: the program owns scrolling; the frame pins to the composer.
    public internal(set) var isTUI = false
    public internal(set) var keyboardVisible = false
    /// The terminal surface is first responder: keys go to the PTY as typed.
    public internal(set) var directTyping = false
    public internal(set) var isScrolledUp = false
    /// Whether the screen shows the Mac's terminal; anything else draws the
    /// connecting placeholder over it.
    public internal(set) var connectionState: TerminalConnectionState
    var sticky = TerminalStickyModifiers()

    // Composer
    public var composerText = ""
    var composerFocused = false
    /// Incremented to ask the composer field to take focus.
    var composerFocusRequest = 0
    /// Focus asked for before the composer was on screen (a new tab).
    var composerFocusOnAppear = false
    public internal(set) var attachments: [ComposerAttachment] = []
    var showPhotoPicker = false {
        didSet { updateCovered() }
    }
    var showFileImporter = false {
        didSet { updateCovered() }
    }
    /// Sends one attachment to the Mac and returns its path there (the
    /// link's `upload` service). Nil hides the attachment menu: without a
    /// Mac to receive them there is nothing honest to attach.
    public var uploader: (@MainActor (_ data: Data, _ name: String) async throws -> String)?
    /// The composer shows its `+` menu: a Mac can receive attachments, or
    /// the DEBUG mock stands in for one so layout captures match live (SPEC M4).
    var attachmentsAvailable: Bool {
        if uploader != nil { return true }
        #if DEBUG
        return session is MockTerminalSession
        #else
        return false
        #endif
    }
    /// The terminal surface is first responder (keys go straight to the PTY).
    var surfaceFocused = false
    /// The terminal or its composer has focus: the key bar shows (SPEC M4).
    var inputFocused: Bool { surfaceFocused || composerFocused }
    /// Attachments are being sent; the composer waits.
    public internal(set) var isUploading = false
    /// Why the last send with attachments failed (shown over the composer).
    public internal(set) var attachmentError: String?
    /// The composer's text was not sent (the Mac is unreachable), or keys
    /// typed meanwhile were dropped: shown over the composer until the
    /// person sends again or edits (termfix-r13 D5, T-INPUT-17).
    public internal(set) var composerNotice: String?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?

    // Artifacts
    public internal(set) var artifacts: [TerminalArtifact] = []
    public var showArtifacts = false {
        didSet {
            if showArtifacts, !oldValue { reconcileArtifactsWithScreen() }
            updateCovered()
        }
    }
    var artifactPath: [TerminalArtifact] = []
    /// Previews of HTML and Markdown show their source.
    var previewShowsSource = false
    /// Scans output for files and links off the main thread.
    @ObservationIgnored private var collector: TerminalArtifactCollector!
    private var reconcilePending = false

    let joystickEngine = JoystickEngine()

    /// Embedded (workspace tab): the page as last seen, for the tab grid card.
    public internal(set) var snapshot: UIImage?

    /// The Mac's screen as plain text (`read-screen`), fetched for the grid
    /// card of a tab not opened in this launch (D5), or of a started tab whose
    /// page is off screen while the grid shows (D6).
    public var cardScreenText: String? {
        didSet { cardScreenTextAt = CACurrentMediaTime() }
    }
    @ObservationIgnored private var cardScreenTextAt: CFTimeInterval = 0
    /// The Mac's screen still reads `cardScreenText`: date it now without a redraw.
    public func confirmCardScreenText() { cardScreenTextAt = CACurrentMediaTime() }
    /// When `snapshot` was last taken from the live page.
    @ObservationIgnored private var cardSnapshotAt: CFTimeInterval = 0

    /// The Mac's screen text arrived after the page's last snapshot.
    public var cardScreenTextIsNewer: Bool { cardScreenText != nil && cardScreenTextAt > cardSnapshotAt }

    /// The page drew output since its card snapshot (`TerminalCardLiveRefresh`).
    public var cardIsBehind: Bool { lastDrawnOutput > cardSnapshotAt }

    /// The page is in a window, so its presented frame can be copied for the card.
    public var canCaptureCard: Bool { controller?.viewIfLoaded?.window != nil }

    /// The page was laid out and its session started in this launch.
    public var pageStarted: Bool { controller?.started == true }

    /// A tab rebuilt after it was cooled out of the warm set (a new, empty
    /// surface): its page as last seen, which the page shows dimmed under the
    /// connecting label until the Mac's terminal is attached again. Cleared on
    /// attach, so a later dropped link never covers the live surface with it.
    public private(set) var coldFrame: UIImage?

    public func restoreLastFrame(_ image: UIImage?) {
        guard let image else { return }
        coldFrame = image
        if snapshot == nil { snapshot = image }
    }

    /// Set by the controller.
    weak var controller: TerminalViewController?

    public init(session: any TerminalSession, artifactSource: any ArtifactSource, title: String = "zsh") {
        self.session = session
        self.artifactSource = artifactSource
        self.title = title
        self.programName = session.programName
        self.connectionState = session.connectionState
        joystickEngine.send = { [weak self] direction in self?.joystick(direction) }
        collector = TerminalArtifactCollector { [weak self] list in self?.artifacts = list }
        sizeClaimer = TerminalSizeClaimer(clock: ContinuousClock()) { [weak self] claims in
            self?.session.setClaimsSize(claims)
        }
    }

    // MARK: Size claim (PROTOCOL.md, "Terminal size claims")

    /// Tells the session when this phone's size should count on the Mac:
    /// only while the page is on screen, settled and taking input, the app is
    /// in the foreground and no sheet covers it.
    @ObservationIgnored private var sizeClaimer: TerminalSizeClaimer<ContinuousClock>!

    /// The page is on screen, settled and taking input (true), or not: off
    /// screen, behind another tab, zoomed out to the grid, mid-swipe.
    public func setPageShown(_ shown: Bool) {
        sizeClaimer.set(pageShown: shown)
    }

    /// The app is in the foreground (false: background, locked).
    public func setAppActive(_ active: Bool) {
        sizeClaimer.set(appActive: active)
    }

    /// A sheet of the page's own covers it (Files and Links, the photo
    /// picker, the file importer).
    private func updateCovered() {
        sizeClaimer?.set(covered: showArtifacts || showPhotoPicker || showFileImporter)
    }

    /// The Mac's output after an attach is drawn: a held last frame (a cold
    /// restore) goes now, not when the attach starts (that showed the stale
    /// frame over the live one, R2-5). Throttled, the new frame is saved for
    /// the next cold launch.
    func liveOutputDrawn() {
        if connectionState.isAttached, coldFrame != nil { coldFrame = nil }
        lastDrawnOutput = CACurrentMediaTime()
        saveFrameSoon()
    }
    @ObservationIgnored private var lastDrawnOutput: CFTimeInterval = 0

    /// Saves the page's frame (for the next cold launch) at most every few
    /// seconds: called when the frame is captured, it returns the writer for
    /// that frame once rendered (ordered against later saves and a close, A5).
    public var frameSaver: (@MainActor () -> @Sendable (UIImage) -> Void)?
    @ObservationIgnored private var lastFrameSave: CFTimeInterval = 0
    @ObservationIgnored private var frameSavePending = false

    /// The page for the next cold launch, without the cursor block (R3-4).
    public func frameForSaving() -> UIImage? {
        controller?.snapshot(hidingCursor: true)
    }

    func saveFrameSoon() {
        guard frameSaver != nil, !frameSavePending else { return }
        let wait = TerminalFrameSaveSchedule.delay(sinceLastSave: lastFrameSave == 0 ? .infinity : CACurrentMediaTime() - lastFrameSave)
        frameSavePending = true
        let requested = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(for: .seconds(wait))
            // Not while output streams (a 370 ms main-thread render): after
            // it pauses, or at most `maxWait` after the save was wanted.
            while let self, let more = TerminalFrameSaveSchedule.remainingWait(
                sinceLastOutput: CACurrentMediaTime() - self.lastDrawnOutput, sinceRequested: CACurrentMediaTime() - requested) {
                try? await ContinuousClock().sleep(for: .seconds(more))
            }
            guard let self else { return }
            frameSavePending = false
            lastFrameSave = CACurrentMediaTime()
            // Taken here, rendered off the main thread (V8 claim 7).
            guard let capture = controller?.captureForSaving(), let write = frameSaver?() else { return }
            Task.detached(priority: .utility) {
                if let image = capture.render() { write(image) }
            }
        }
    }

    func ingest(_ event: TerminalSessionEvent) {
        let connection = connectionState.applying(event)
        if connection != connectionState { connectionState = connection }
        switch event {
        case .output:
            // The bytes are scanned once per display frame (`scanOutput`).
            break
        case .alternateScreen(let on):
            isTUI = on
            programName = session.programName
        case .title(let text):
            title = text
            programName = session.programName
        case .exited:
            break
        case .connection:
            break
        case .inputNotSent:
            composerNotice = TerminalConnectionState.inputNotSentNotice
        case .hostGrid, .hostGridOwner:
            break
        }
    }

    /// Files and links in a batch of output (the screen's per-frame batch).
    func scanOutput(_ data: Data) {
        // A full-screen program's screen is drawing, not output: its rows
        // are not paths (round 5).
        guard !isTUI else { return }
        collector.scan(data)
        if showArtifacts { scheduleReconcile() }
    }

    /// The stream scan sees a path the sender broke at the right margin as
    /// two references. The surface's screen text has logical lines (soft
    /// wraps joined, full-width rows continued), so the list is rescanned
    /// against it whenever Files and Links is open.
    func reconcileArtifactsWithScreen() {
        // Not while a TUI owns the screen (its screen is not the shell's
        // output); rows are joined only where Ghostty soft-wrapped them,
        // which its text read already does (R4-2).
        guard !isTUI, let surface = controller?.surface, let text = surface.screenText() else { return }
        collector.reconcile(screenText: text, columns: nil)
    }

    /// While Files and Links is open, the list is reconciled with the
    /// screen at most every `reconcileInterval` (reading the screen's text
    /// takes the surface lock and walks the scrollback; per output frame it
    /// would cost the main thread under a flood).
    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        let wait = max(0, Self.reconcileInterval - (CACurrentMediaTime() - lastReconcile))
        Task { @MainActor [weak self] in
            if wait > 0 { try? await ContinuousClock().sleep(for: .seconds(wait)) }
            guard let self else { return }
            reconcilePending = false
            lastReconcile = CACurrentMediaTime()
            if showArtifacts { reconcileArtifactsWithScreen() }
        }
    }

    static let reconcileInterval: CFTimeInterval = 0.5
    @ObservationIgnored private var lastReconcile: CFTimeInterval = 0

    var composerPlaceholder: String {
        directTyping ? "Typing into terminal" : "Send to \(programName)"
    }

    // MARK: Actions

    /// The always-visible keyboard button: hide, or show for the last input target.
    public func toggleKeyboard() {
        if keyboardVisible {
            controller?.hideKeyboard()
        } else if isTUI || directTyping {
            controller?.focusTerminal()
        } else {
            focusComposer()
        }
    }

    public func hideKeyboard() {
        controller?.hideKeyboard()
    }

    /// Opens the files-and-links sheet.
    public func showFilesAndLinks() {
        showArtifacts = true
    }

    public func paste() {
        controller?.surface.paste(nil)
    }

    /// Ctrl-<letter> to the program (`c` interrupts, `l` clears).
    public func sendControl(_ letter: Character) {
        keyBar(.chord(letter))
    }

    #if DEBUG
    /// DEBUG: the controller's layout and viewport state, for demo timelines.
    public var debugState: String { controller?.debugState ?? "-" }
    #endif

    /// Refreshes `snapshot` from the live page (the grid is about to show it).
    public func captureSnapshot() {
        if let image = controller?.snapshot() {
            cardRenders += 1
            cardSnapshotAt = CACurrentMediaTime()
            snapshot = image
            #if DEBUG
            if CommandLine.arguments.contains("-CmuxMobileDumpCard"), let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? image.pngData()?.write(to: dir.appendingPathComponent("card-snapshot.png"))
            }
            #endif
        }
    }

    /// The grid is open and the page drew output (D6): its card is taken
    /// again, the frame copied here and composed off the main thread (the
    /// main-thread render was 150-370 ms under load, V8 claim 7). A capture
    /// with no presented frame keeps the card as it is.
    public func refreshCardSnapshot() {
        guard let capture = controller?.capture(hidingCursor: false), capture.surface != nil || capture.fallback != nil else { return }
        cardRenders += 1
        let serial = cardRenders
        cardSnapshotAt = CACurrentMediaTime()
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) { capture.render() }.value
            // A newer card (another refresh, the grid opening) wins.
            guard let self, let image, serial == self.cardRenders else { return }
            self.snapshot = image
        }
    }
    @ObservationIgnored private var cardRenders = 0

    public func focusComposer() {
        directTyping = false
        // The field may not exist yet (a new tab whose page just appeared):
        // it then takes focus once it is in a window.
        composerFocusOnAppear = true
        composerFocusRequest += 1
    }

    /// The send button: text plus Return; empty is a bare Return (Enter).
    /// With attachments, each is uploaded to the Mac first, then the real
    /// paths (shell-quoted) and the text go as one paste; Return follows when
    /// there was text (a prompt to run), not for paths alone, which the
    /// person finishes (`ComposerSubmit`).
    public func send() {
        guard composerMaySend() else { return }
        guard attachments.isEmpty else {
            sendAttachments(pressReturn: true)
            return
        }
        controller?.surface.sendText(composerText, pressReturn: true, fullScreenApp: isTUI)
        composerText = ""
    }

    public func sendWithoutReturn() {
        guard composerMaySend() else { return }
        guard attachments.isEmpty else {
            sendAttachments(pressReturn: false)
            return
        }
        controller?.surface.sendText(composerText, pressReturn: false, fullScreenApp: isTUI)
        composerText = ""
    }

    /// The Mac's terminal can take a command now. Otherwise the text stays in
    /// the composer, marked not sent: it is never queued to run whenever the
    /// Mac comes back (termfix-r13 D5: a command ran 15.4 minutes later).
    private func composerMaySend() -> Bool {
        if let notice = connectionState.composerNotSentNotice {
            composerNotice = notice
            return false
        }
        composerNotice = nil
        return true
    }

    /// The person edited the draft: an old "not sent" note no longer applies to it.
    func composerEdited() {
        if composerNotice != nil { composerNotice = nil }
    }

    private func sendAttachments(pressReturn: Bool) {
        guard !isUploading else { return }
        guard let uploader else {
            attachmentError = "Connect to the Mac to send attachments."
            return
        }
        let pending = attachments
        isUploading = true
        attachmentError = nil
        uploadTask = Task { [weak self] in
            var paths: [String] = []
            for attachment in pending {
                do {
                    let data = try attachment.contents()
                    paths.append(try await uploader(data, attachment.name))
                } catch {
                    guard let self else { return }
                    self.isUploading = false
                    self.attachmentError = "Couldn't send \(attachment.name): \(Self.message(error))"
                    return
                }
            }
            guard let self else { return }
            self.isUploading = false
            let submit = ComposerSubmit(attachmentPaths: paths, text: self.composerText, pressReturn: pressReturn)
            self.controller?.surface.perform(submit)
            self.composerText = ""
            self.attachments.removeAll { attachment in pending.contains { $0.id == attachment.id } }
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }


    func addAttachment(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
    }

    /// A tapped attachment, before sending: every attachment opens full screen, to swipe between.
    func previewAttachment(_ id: ComposerAttachment.ID) {
        let request = FilePreviewRequest(files: attachments.map(\.localFile), startingAt: id.uuidString)
        controller?.presentFilePreview(request)
    }

    func removeAttachment(_ id: ComposerAttachment.ID) {
        attachments.removeAll { $0.id == id }
        if attachments.isEmpty { attachmentError = nil }
    }

    func clearAttachmentError() { attachmentError = nil }

    // MARK: Key bar

    func keyBar(_ key: KeyBarKey) {
        guard let surface = controller?.surface else { return }
        switch key {
        case .escape: surface.sendKey(usage: TerminalHIDUsage.escape)
        case .tab: surface.sendKey(usage: TerminalHIDUsage.tab)
        case .shiftTab: surface.sendKey(usage: TerminalHIDUsage.tab, mods: .shift)
        case .control: surface.tapSticky(.control)
        case .alternate: surface.tapSticky(.alternate)
        case .up: surface.sendKey(usage: TerminalHIDUsage.up)
        case .down: surface.sendKey(usage: TerminalHIDUsage.down)
        case .left: surface.sendKey(usage: TerminalHIDUsage.left)
        case .right: surface.sendKey(usage: TerminalHIDUsage.right)
        case .chord(let letter): surface.sendControl(letter)
        case .symbol(let text): surface.perform(surface.input.insertText(text))
        case .paste: surface.paste(nil)
        case .hideKeyboard: controller?.hideKeyboard()
        }
        sticky = surface.input.sticky
    }

    /// The composer is about to insert `text`. With ctrl or alt on, the key
    /// goes to the terminal instead (SPEC M1); returns false then.
    func composerShouldInsert(_ text: String) -> Bool {
        guard let surface = controller?.surface, let actions = surface.input.composerKey(text) else { return true }
        surface.perform(actions)
        sticky = surface.input.sticky
        return false
    }

    func joystick(_ direction: JoystickDirection) {
        keyBar(direction.key)
    }

    // MARK: Scrolling

    public func scrollToBottom() {
        controller?.scrollToBottom(animated: true)
    }
}

/// A photo, video or file waiting in the composer, with its bytes (or the
/// local file holding them) to upload.
public struct ComposerAttachment: Identifiable, Sendable {
    public enum Kind: Sendable { case image, video, file }
    public let id = UUID()
    public var kind: Kind
    public var name: String
    public var thumbnail: UIImage?
    public var byteCount: Int?
    public var data: Data?
    /// A local copy (picked videos), read at send.
    public var fileURL: URL?

    public init(kind: Kind, name: String, thumbnail: UIImage? = nil, byteCount: Int? = nil, data: Data? = nil, fileURL: URL? = nil) {
        self.kind = kind
        self.name = name
        self.thumbnail = thumbnail
        self.byteCount = byteCount ?? data?.count
        self.data = data
        self.fileURL = fileURL
    }

    struct Unreadable: Error, LocalizedError {
        var errorDescription: String? { "its contents couldn't be read on this iPhone" }
    }

    /// The attachment as the file preview reads it.
    public var localFile: LocalFile {
        LocalFile(id: id.uuidString, name: name, data: data, isImage: kind == .image, fileURL: fileURL)
    }

    func contents() throws -> Data {
        if let data { return data }
        if let fileURL { return try Data(contentsOf: fileURL, options: .mappedIfSafe) }
        throw Unreadable()
    }
}
#endif
