#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileLinkFFI
public import CmuxMobileRealtime
public import CmuxMobileDesign
import CmuxMobileTransport
import Foundation
import Observation
import OSLog
import UIKit

private let modelLog = Logger(subsystem: "dev.cmux.mobile", category: "terminal")

/// The terminal screen's state, shared by the UIKit controller (surface,
/// scrolling, keyboard tracking) and the SwiftUI chrome (toolbar, composer,
/// key bar, sheets). The session is the data source.
@MainActor
@Observable
public final class TerminalModel {
    /// Recovery supplied by the shell: retries the owning Mac and its attach.
    public var reconnect: (@MainActor () async -> Void)?
    public let session: any TerminalSession
    public let artifactSource: any ArtifactSource

    public internal(set) var title: String
    public internal(set) var programName: String
    /// The Mac the session runs on (`Workspace.macID`): the terminal shows that Mac's terminal
    /// theme (``CmuxMobileTerminalThemes``). Nil for a placeholder or mock session.
    public var hostMacID: String?
    /// The terminal theme the surface shows now (its card paints the same background); nil until
    /// a Mac ever sent one.
    public internal(set) var hostTheme: CmuxMobileTerminalTheme?
    /// Alternate screen: the program owns scrolling; the frame pins to the composer.
    public internal(set) var isTUI = false
    public internal(set) var keyboardVisible = false
    /// The terminal surface is first responder: keys go to the PTY as typed.
    public internal(set) var directTyping = false
    public internal(set) var isScrolledUp = false
    /// The last line sent from the phone, while its row is off screen: the
    /// top strip shows it, and a tap there scrolls back to it
    /// (`TerminalLastSentStrip`). Nil hides the strip.
    public internal(set) var lastSentStripText: String?
    /// Whether the screen shows the Mac's terminal; anything else draws the
    /// connecting placeholder over it.
    public internal(set) var connectionState: TerminalConnectionState
    /// Says when a dropped connection may show its line (after 10 s).
    @ObservationIgnored public let quietStatus: QuietStatusGate
    /// What is going on with the connection: nil while attached and for the
    /// first ``QuietStatusGate/threshold`` of an outage (the page keeps
    /// showing its last frame meanwhile). It takes no row on the page: the
    /// title pill's subtitle says the state, and the page menu offers
    /// Reconnect (``reconnect``) only while this is set.
    public var connectionLine: String? {
        quietStatus.isShown ? connectionState.quietLine : nil
    }

    /// The page menu's Reconnect: only past the quiet bound of an outage,
    /// and only with a recovery to run.
    public var offersReconnect: Bool { connectionLine != nil && reconnect != nil }
    var sticky = TerminalStickyModifiers()

    // Composer
    /// The draft. Only the text field reads it while typing: a view body that read it was
    /// built again on every key (the whole composer, its strip and its buttons: tens of size
    /// questions per key in a long draft; Leo, 2026-11-23). Views read `composerHasText`.
    public var composerText = "" {
        didSet {
            guard composerText != oldValue else { return }
            let hasText = !composerText.isEmpty
            if composerHasText != hasText { composerHasText = hasText }
            if !puttingComposerText { composerEdited() }
            onDraftChange?()
        }
    }
    /// Set while the model itself writes the draft (``putComposerText(_:)``): that is not the
    /// person editing it, so a notice set with it stays.
    @ObservationIgnored private var puttingComposerText = false
    /// The model's own write of the draft (a dropped send coming back, a sent one cleared):
    /// unlike the person's edit, it keeps the composer's notice. Since #52667 every write of
    /// `composerText` counted as an edit and cleared the "not sent" notice it came back with.
    func putComposerText(_ text: String) {
        puttingComposerText = true
        defer { puttingComposerText = false }
        composerText = text
    }
    /// Whether the draft has any text: changes on the first key and on clearing, not per key.
    public private(set) var composerHasText = false
    /// Told when the draft to keep changes (``draftToKeep``): the shell writes it to disk.
    @ObservationIgnored public var onDraftChange: (@MainActor () -> Void)?
    /// Voice mode on this terminal's agent (set by the shell); the composer's
    /// voice button shows only when there is one.
    public var voiceSource: (any AgentVoiceSource)?
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
    public var uploader: (@MainActor (_ payload: LinkUpload.Payload, _ name: String) async throws -> String)?
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
    #if DEBUG
    /// Set by `demoConnection`: the link state a demo holds.
    @ObservationIgnored var demoHeldConnection: TerminalConnectionState?
    #endif
    /// The terminal surface is first responder (keys go straight to the PTY).
    var surfaceFocused = false
    /// The terminal or its composer has focus.
    var inputFocused: Bool { surfaceFocused || composerFocused }
    /// The composer is shown (classic cmux iOS: open by default, closed with
    /// the compose key for this page's life).
    public internal(set) var composerPresented = true
    /// Hide Toolbar took the key row and the composer away until the next terminal tap.
    public internal(set) var chromeHidden = false
    /// Wide (the key row's Wide key, the page menu's Wide View): the grid is
    /// wider than the page (`TerminalHostGridLayout.wideColumns`), so a wide
    /// table or a long line stays one row and the page pans sideways to it.
    /// For this page's life.
    public internal(set) var wideOutput = false
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
    /// surface): its page as last seen, for the tab's grid card. The page itself
    /// never shows it (a still takes no scroll or tap): its surface shows the
    /// kept rows live (``restoreLastRows(_:)``). Cleared once the Mac's output
    /// is drawn, so a later dropped link never stands for the live surface.
    public private(set) var coldFrame: UIImage?

    public func restoreLastFrame(_ image: UIImage?) {
        guard let image else { return }
        coldFrame = image
        restoredFrame = image
        if snapshot == nil { snapshot = image }
    }

    /// The page as last seen, as rows (`TerminalSeed`): fed into this host's fresh surface
    /// when its session starts (``takeSeed()``), so a restored page is live at once.
    @ObservationIgnored private var seedRows: String?
    /// The rows this host was given, kept for a host cooled before it drew the Mac's output.
    @ObservationIgnored private var restoredRows: String?
    /// The surface was fed the page's rows before the attach: it shows them live (scrollable,
    /// taking keys), so nothing covers it while it connects.
    public private(set) var seeded = false

    /// The page's rows as last seen on this phone (a cold launch, a tab back from the warm set).
    public func restoreLastRows(_ rows: String?) {
        guard let rows, !rows.isEmpty else { return }
        seedRows = rows
        restoredRows = rows
    }

    /// The bytes this host's fresh surface shows before the Mac's replay: its kept rows, else
    /// the Mac's screen text when it came first. Once, at the session's start.
    func takeSeed() -> Data? {
        guard !seeded, let rows = seedRows ?? cardScreenText.flatMap(TerminalSeed.rows(fromScreenText:)) else { return nil }
        seedRows = nil
        seeded = true
        return TerminalSeed.bytes(rows: rows)
    }

    /// The page's rows for the next host or launch: nil while the surface holds nothing of the
    /// Mac's (the same gate as a frame, `TerminalFrameKeep`). Takes the surface lock: on demand.
    public func rowsForSaving() -> String? {
        guard drewLiveOutput, let text = controller?.surface.screenText() else { return nil }
        return TerminalSeed.rows(fromScreenText: text)
    }

    /// What a cooled host hands the next one: its live rows, else the rows it was given.
    public func rowsToKeep() -> String? {
        rowsForSaving() ?? restoredRows
    }

    /// The cached frame this host was given (`restoreLastFrame`), kept after
    /// live output replaces `coldFrame`: what the tab keeps when its host
    /// goes before its page drew anything worth keeping.
    @ObservationIgnored private var restoredFrame: UIImage?

    /// The page drew the Mac's output while attached, since this host was
    /// built. Until then the surface holds nothing of the Mac's (a blank
    /// page, or one from before the first attach), and no frame from it may
    /// replace the tab's cached frame (`TerminalFrameKeep`).
    @ObservationIgnored public private(set) var drewLiveOutput = false

    /// Set by the controller.
    weak var controller: TerminalViewController?

    public init(session: any TerminalSession, artifactSource: any ArtifactSource, title: String = "zsh",
                quietStatus: QuietStatusGate = QuietStatusGate()) {
        self.quietStatus = quietStatus
        self.session = session
        self.artifactSource = artifactSource
        self.title = title
        self.programName = session.programName
        self.connectionState = session.connectionState
        quietStatus.update(down: !session.connectionState.isAttached)
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
        controller?.appActiveChanged(active)
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
        if connectionState.isAttached {
            drewLiveOutput = true
            if coldFrame != nil { coldFrame = nil }
        }
        lastDrawnOutput = CACurrentMediaTime()
        saveFrameSoon()
    }
    @ObservationIgnored private var lastDrawnOutput: CFTimeInterval = 0

    /// The attached terminal's reset is placed (its replay parsed, or the
    /// replay gate or held frame ran out): the surface now shows the Mac's
    /// screen, even an empty one that sends no bytes after the reset, so a
    /// held last frame goes. Without this, an attach to an empty terminal
    /// left the cached frame over the live surface until the next output.
    func mirrorPlaced() {
        if connectionState.isAttached, coldFrame != nil { coldFrame = nil }
    }

    /// Saves the page's frame (for the next cold launch) at most every few
    /// seconds: called when the frame is captured, it returns the writer for
    /// that frame once rendered (ordered against later saves and a close, A5).
    public var frameSaver: (@MainActor () -> @Sendable (UIImage) -> Void)?
    @ObservationIgnored private var lastFrameSave: CFTimeInterval = 0
    @ObservationIgnored private var frameSavePending = false

    /// The page for the next cold launch, without the cursor block (R3-4):
    /// nil while it may not replace the cached frame (`TerminalFrameKeep`).
    public func frameForSaving() -> UIImage? {
        guard drewLiveOutput else { return nil }
        return TerminalFrameKeep.kept(controller?.snapshot(hidingCursor: true), drewLiveOutput: drewLiveOutput)
    }

    /// What the tab keeps as its cached frame when this host goes (cooled,
    /// or replaced by its live session): the live page once it drew the
    /// Mac's output, else the cached frame the host was given. Never a blank
    /// page, nor one from before the first attach.
    public func frameToKeep() -> UIImage? {
        if drewLiveOutput, let live = frameForSaving() ?? TerminalFrameKeep.kept(snapshot, drewLiveOutput: true) { return live }
        return restoredFrame
    }

    func saveFrameSoon() {
        guard drewLiveOutput, frameSaver != nil, !frameSavePending else { return }
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
                if let image = TerminalFrameKeep.kept(capture.render(), drewLiveOutput: true) { write(image) }
            }
        }
    }

    func ingest(_ event: TerminalSessionEvent) {
        var connection = connectionState.applying(event)
        #if DEBUG
        // A demo's link state holds while the mock shell keeps printing.
        if let held = demoHeldConnection { connection = held }
        #endif
        if connection != connectionState {
            connectionState = connection
            quietStatus.update(down: !connection.isAttached)
        }
        // Attached again: a held composer send went out (or was dropped, which says so
        // first); a later drop must never put already-sent text back.
        if connection.isAttached { heldComposerSend = nil }
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
        case .inputNotSent(let bytes) where bytes <= 0:
            // Nothing the person typed was dropped: nothing to say.
            break
        case .inputNotSent:
            composerNotice = TerminalConnectionState.inputNotSentNotice
            // A composer send that waited out a blip and was dropped comes back to edit.
            if let held = heldComposerSend, !composerText.isEmpty, composerText == held.text {
                // Refused inside `send` itself (the hold was full or already dropped): the
                // composer keeps its text.
                composerSendRefused = true
            } else if let held = heldComposerSend, composerText.isEmpty,
               ProcessInfo.processInfo.systemUptime - held.at <= Self.heldComposerSendWindow {
                putComposerText(held.text)
            }
            heldComposerSend = nil
        case .inputHeld(let bytes):
            heldKeyBytes = max(0, bytes)
        case .hostGrid, .hostGridOwner, .paintMark:
            break
        }
    }

    /// Typed bytes waiting for the attach (``TerminalSessionEvent/inputHeld(bytes:)``): while
    /// any do, the composer says so and offers Discard (``discardHeldKeys()``).
    public internal(set) var heldKeyBytes = 0

    /// The person's Discard on the pending-keys line: the held keys are never sent, and their
    /// predicted glyphs go.
    public func discardHeldKeys() {
        session.discardHeldInput()
        heldKeyBytes = 0
        controller?.surface.prediction?.inputDropped()
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

    /// Classic cmux iOS's placeholder (iMessage's): the field is a message to the program.
    let composerPlaceholder = "Message"

    // MARK: Actions

    /// The key row's keyboard key: hide, or show for the last input target.
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

    /// Clear Screen and Scrollback can run now: on a Mac terminal while it is attached
    /// (as on the Mac, a full-screen app is left as it is), else as Ctrl-L.
    public var canClearScreenAndScrollback: Bool {
        session.clearsHistory ? connectionState.isAttached : true
    }

    /// The Mac's Clear Screen and Scrollback (Cmd-K): the Mac's daemon clears the terminal,
    /// so its scrollback goes on the Mac and on every phone (`clear-history`). A session
    /// with no Mac behind it gets Ctrl-L.
    public func clearScreenAndScrollback() {
        guard session.clearsHistory else { return sendControl("l") }
        let session = session
        Task { @MainActor in
            do {
                try await session.clearHistory()
            } catch {
                // Nothing changed on the Mac (an inline program's input reaches into the
                // history, the link dropped): the person feels it did not clear.
                modelLog.error("clear-history failed: \(String(describing: error), privacy: .public)")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// Opens a web link on the Mac: a cmux browser tab beside the terminal in the workspace
    /// (the page sets it, like the Mac's Cmd-click); nil when the Mac can't open tabs. Not
    /// observed: the page sets it while SwiftUI builds it.
    @ObservationIgnored public var linkOpener: (@MainActor (URL) -> Void)?

    /// Where this terminal's links open (``TerminalLinkRoute``).
    var linkRoute: TerminalLinkRoute { TerminalLinkRoute(opensOnMac: linkOpener != nil) }

    /// Who can reach `url`: the Rust classifier (`link_open_side`) reads its host.
    func linkReach(_ url: URL) -> TerminalLinkReach {
        switch linkOpenSide(url: url.absoluteString) {
        case .phone: .phone
        case .mac: .mac
        case .notWeb: .notWeb
        }
    }

    /// The long-press menu's row for the device a tap does not open `url` on.
    func otherLinkDevice(_ url: URL) -> TerminalLinkAction? {
        linkRoute.otherDevice(for: linkReach(url))
    }

    /// Opens a web link the person tapped or picked in the menu, where
    /// ``TerminalLinkRoute`` says: a public page on this iPhone in a Safari view (Safari's
    /// passkeys, AutoFill and cookies work there, unlike in a web view or a page streamed
    /// from the Mac), a page only the Mac reaches in a browser tab on the Mac.
    public func openLink(_ url: URL, action: TerminalLinkAction = .tap) {
        switch linkRoute.destination(for: url, reach: linkReach(url), action: action) {
        case .phone(let page): if controller?.presentWebPage(page) != true { UIApplication.shared.open(page) }
        case .systemBrowser(let page): UIApplication.shared.open(page)
        case .mac(let page): linkOpener?(page)
        case .none: break
        }
    }

    /// Find… (the page menu, Cmd-F): the find bar over the terminal's rows.
    public func showFind() {
        controller?.presentFind()
    }

    /// Copy Mode is on (Select Text…, Shift-Cmd-M).
    public internal(set) var copyModeActive = false

    /// Select Text… (the page menu): Copy Mode with the cursor's row selected; vi keys from a
    /// hardware keyboard or the handles move it, Copy copies it.
    public func selectText() {
        controller?.presentCopyMode()
    }

    /// Copy Mode can start: the shell's rows (a full-screen app selects with a long press).
    public var canSelectText: Bool { !isTUI }

    /// The Mac's Select All: every row, scrollback included, with Copy in the edit menu.
    public func selectAll() {
        controller?.selectAllText()
    }

    /// The Mac's Scroll to Top: the first row of the scrollback.
    public func scrollToTop() {
        controller?.scrollToTop()
    }

    /// Send Text… (the page menu): asks for the text.
    public func showSendText() {
        controller?.presentSendText()
    }

    /// The Mac's Send Text…: `text` typed into the terminal as is, with no Return.
    public func sendText(_ text: String) {
        guard !text.isEmpty, connectionState.composerNotSentNotice == nil else { return }
        controller?.surface.sendText(text, pressReturn: false, fullScreenApp: isTUI)
    }

    #if DEBUG
    /// DEBUG: the controller's layout and viewport state, for demo timelines.
    public var debugState: String { controller?.debugState ?? "-" }
    #endif

    /// Grid sizes this page sent the Mac (`TerminalViewController.sendResize`),
    /// for demos and UI tests.
    public internal(set) var ptyResizesSent = 0
    /// Grids the page took on the primary screen whose columns were not the
    /// phone's (the Mac's wide grid drawn on the phone: "uncompact"), for
    /// the projection harness.
    public internal(set) var wideGridsShown = 0
    /// Mirror resets the page laid out again (each a replay).
    public internal(set) var mirrorResets = 0
    /// Back in the foreground: milliseconds from the app becoming active to
    /// the first display frame that shows the terminal right (the phone's
    /// width on the primary screen, no held frame, no replay or output
    /// pending); -1 before the first return, -2 when none came in 5 s.
    public internal(set) var lastReturnMs = -1
    /// Display frames, during a soft keyboard transition and half a second
    /// after it, whose terminal on the primary screen was narrower than the
    /// phone ("i dont see the point of a narrower-than-iphone terminal").
    public internal(set) var narrowKeyboardFrames = 0
    /// Display frames of a soft keyboard transition in which the cursor's row
    /// moved against the keyboard (down while it shows, up while it hides):
    /// the terminal bouncing.
    public internal(set) var keyboardBounces = 0
    /// Pinches and double taps that zoomed the alternate screen's grid.
    public internal(set) var zoomGestures = 0
    /// The alternate screen's zoom over the Mac's grid (1: readable).
    public internal(set) var zoomScale: Double = 1
    /// The settle probe (``TerminalViewController/startSettleProbe``):
    /// milliseconds from its start to the first display frame that shows the
    /// full-screen app right; -1 while it runs, -2 when none came in 5 s.
    public internal(set) var settleMs = -1
    /// Display frames of a full-screen app drawn at a grid that is not its
    /// final one (a size change still on its way: "uncompact then squish").
    public internal(set) var unsettledTUIFrames = 0
    #if DEBUG
    /// DEBUG: every page's `ptyResizesSent` added up (the keyboard pin trace's `rz=`).
    public internal(set) static var debugResizesSentTotal = 0
    /// DEBUG: every terminal surface's presented frames added up (the keyboard pin trace's `tp=`).
    public internal(set) static var debugPresentsTotal = 0
    /// DEBUG: posted when the terminal surface takes a key from the system keyboard
    /// (the keyboard pin trace's `ev=keyAccepted`, the motion bench's time to interactive).
    public static let debugKeyAccepted = Notification.Name("cmux.debug.terminal.keyAccepted")
    /// DEBUG: the terminal demo driver's last step (`TerminalDemoDriver`).
    var demoNote = "start"
    /// DEBUG: the grid columns the full-screen app ends at (the mock Mac's
    /// PTY), nil while a size change is on its way (the settle probe).
    @ObservationIgnored var demoFinalColumns: (@MainActor () -> Int?)?
    #endif

    /// Refreshes `snapshot` from the live page, rendered here on the main
    /// thread: for callers that need the picture now (the background save).
    public func captureSnapshot() {
        if let image = controller?.snapshot() {
            cardRenders += 1
            cardSnapshotAt = CACurrentMediaTime()
            snapshot = image
            Self.dumpCard(image)
        }
    }

    /// The grid is about to open on this page: the frame is copied here and
    /// composed off the main thread, and `snapshot` follows once it is
    /// (`TerminalTabHost.prepareCard`). Rendered in the tap (`captureSnapshot`),
    /// it was the zoom's first frame: Leo, 2026-11-22, "the button clicking is
    /// not smooth. it's not 120fps." The zoom draws the live page, and the
    /// still is first shown when the grid settles (`showsStaticCard`), a
    /// spring later than the render takes.
    public func captureSnapshotOffMain() {
        guard let capture = controller?.capture(hidingCursor: false) else { return }
        renderCard(capture)
    }

    /// The grid is open and the page drew output (D6): its card is taken
    /// again, the frame copied here and composed off the main thread (the
    /// main-thread render was 150-370 ms under load, V8 claim 7). A capture
    /// with no presented frame keeps the card as it is.
    public func refreshCardSnapshot() {
        guard let capture = controller?.capture(hidingCursor: false), capture.surface != nil || capture.fallback != nil else { return }
        renderCard(capture)
    }

    /// Composes `capture` off the main thread into `snapshot`; a newer card
    /// (another refresh, the grid opening, a main-thread capture) wins.
    private func renderCard(_ capture: TerminalPageCapture) {
        cardRenders += 1
        let serial = cardRenders
        cardSnapshotAt = CACurrentMediaTime()
        cardRender = Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) { capture.render() }.value
            guard let self, let image, serial == self.cardRenders else { return }
            self.snapshot = image
            Self.dumpCard(image)
        }
    }

    /// The last off-main card render (tests await it).
    @ObservationIgnored private(set) var cardRender: Task<Void, Never>?
    @ObservationIgnored private var cardRenders = 0

    private static func dumpCard(_ image: UIImage) {
        #if DEBUG
        if CommandLine.arguments.contains("-CmuxMobileDumpCard"), let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? image.pngData()?.write(to: dir.appendingPathComponent("card-snapshot.png"))
        }
        #endif
    }

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
        holdComposerText()
        // The draft and its Return go to the Mac's terminal as one request when
        // the session can: a paste plus Return (`sendPasteAndSubmit`), or a
        // one-line draft for a full-screen app typed plus Return
        // (`sendTypedAndSubmit`), so a blip never delivers the text without
        // its Return. A bare Return, or a session with no Mac daemon, goes
        // through the mirror as before.
        let submit = ComposerSubmit(text: composerText, pressReturn: true, fullScreenApp: isTUI)
        let text = composerText
        controller?.noteSent(text)
        composerSending = true
        let viaDaemon = sendThroughSession(
            submit,
            notSent: { [weak self] in self?.composerSendNotSent(text) },
            maybeSent: { [weak self] in self?.composerSendMaybeSent(text) }
        )
        composerSending = false
        if !viaDaemon {
            controller?.surface.sendText(text, pressReturn: true, fullScreenApp: isTUI)
        }
        finishComposerSend()
    }

    /// `submit`'s text and its Return as one request where the terminal runs
    /// (a Mac daemon's `send` with `submit`), when the session can: a paste
    /// (``TerminalSession/sendPasteAndSubmit(_:notSent:maybeSent:)``) or typed
    /// text (``TerminalSession/sendTypedAndSubmit(_:notSent:maybeSent:)``).
    /// Never the text and a separate Return that a link blip can split (Leo,
    /// 2026-11-21: "the text goes through. But then the send doesn't go
    /// through"). False: the caller sends through the mirror.
    private func sendThroughSession(
        _ submit: ComposerSubmit,
        notSent: @escaping @MainActor () -> Void,
        maybeSent: @escaping @MainActor () -> Void
    ) -> Bool {
        guard submit.steps.count == 2, submit.steps.last == .enter else { return false }
        switch submit.steps.first {
        case .paste(let text): return session.sendPasteAndSubmit(text, notSent: notSent, maybeSent: maybeSent)
        case .type(let text): return session.sendTypedAndSubmit(text, notSent: notSent, maybeSent: maybeSent)
        default: return false
        }
    }

    /// Inside `send`, handing the draft to the session.
    @ObservationIgnored private var composerSending = false

    /// The session dropped, refused or got an error for a composer send
    /// (``TerminalSession/sendPasteAndSubmit(_:notSent:maybeSent:)``): never silent.
    /// The notice shows and the text comes back to an empty composer (one the
    /// person typed into since keeps what they typed).
    private func composerSendNotSent(_ text: String) {
        composerNotice = TerminalConnectionState.composerSendNotSentNotice
        heldComposerSend = nil
        if composerSending {
            composerSendRefused = true
        } else if composerText.isEmpty {
            putComposerText(text)
        }
    }

    /// A composer send went out and its answer never came: the Mac may have
    /// typed it. The notice says so, and the text never comes back as unsent
    /// (Leo, 2026-11-23: "there's like a sort of like double send type
    /// thing"); a blip's restore that already put it back is taken out again.
    private func composerSendMaybeSent(_ text: String) {
        composerNotice = TerminalConnectionState.composerSendMaybeSentNotice
        heldComposerSend = nil
        if composerSending {
            composerSendRefused = false
        } else if composerText == text {
            putComposerText("")
        }
    }

    /// A composer send made while the terminal is not attached (a blip): the
    /// session holds its keys, and drops them if the terminal does not come
    /// back in time. Its text, with when it was sent, comes back then.
    @ObservationIgnored var heldComposerSend: (text: String, at: TimeInterval)? {
        // A held send is still the draft until the Mac has it (``draftToKeep``).
        didSet { if oldValue?.text != heldComposerSend?.text { onDraftChange?() } }
    }
    /// How long after a held send its text may come back (the session's hold, with room for the attach).
    static let heldComposerSendWindow: TimeInterval = 30

    /// The session refused the composer's text while `send` was handing it over.
    @ObservationIgnored var composerSendRefused = false

    /// Empties the composer after a send, unless the session refused the text on the spot.
    private func finishComposerSend() {
        if composerSendRefused {
            composerSendRefused = false
        } else {
            putComposerText("")
        }
    }

    private func holdComposerText() {
        // A refusal is about this send only: a stale one never keeps the next send's text.
        composerSendRefused = false
        heldComposerSend = connectionState.isAttached || composerText.isEmpty
            ? nil : (composerText, ProcessInfo.processInfo.systemUptime)
    }

    /// Voice mode's prompt: the user's words typed into the terminal with
    /// Return, as the composer's send does, without touching the draft. Words
    /// for a Mac that can't take them now are dropped, never queued (D5).
    /// Returns false when nothing was typed.
    @discardableResult
    public func sendVoicePrompt(_ text: String) -> Bool {
        guard connectionState.composerNotSentNotice == nil else { return false }
        controller?.noteSent(text)
        let submit = ComposerSubmit(text: text, pressReturn: true, fullScreenApp: isTUI)
        if sendThroughSession(
            submit,
            notSent: { [weak self] in self?.composerNotice = TerminalConnectionState.composerSendNotSentNotice },
            maybeSent: { [weak self] in self?.composerNotice = TerminalConnectionState.composerSendMaybeSentNotice }
        ) {
            return true
        }
        guard let controller else { return false }
        controller.surface.perform(submit)
        return true
    }

    public func sendWithoutReturn() {
        guard composerMaySend() else { return }
        guard attachments.isEmpty else {
            sendAttachments(pressReturn: false)
            return
        }
        holdComposerText()
        controller?.surface.sendText(composerText, pressReturn: false, fullScreenApp: isTUI)
        finishComposerSend()
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
                    paths.append(try await uploader(try attachment.payload(), attachment.name))
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
            let draft = self.composerText
            if pressReturn { self.controller?.noteSent(draft) }
            let viaDaemon = self.sendThroughSession(
                submit,
                notSent: { [weak self] in self?.composerSendNotSent(draft) },
                maybeSent: { [weak self] in self?.composerSendMaybeSent(draft) }
            )
            if !viaDaemon { self.controller?.surface.perform(submit) }
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

    #if DEBUG
    /// Demo drivers (`ws-terminal-composer`): a draft, with two photos and a
    /// file attached when asked, for gallery captures of the composer.
    public func demoFillComposer(_ text: String, attachments withAttachments: Bool, file: Bool = true) {
        composerText = text
        guard withAttachments else { return }
        let colors: [UIColor] = [.systemOrange, .systemTeal]
        for (index, color) in colors.enumerated() {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 168, height: 168)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 168, height: 168))
                UIColor.white.withAlphaComponent(0.35).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 40, y: 40, width: 88, height: 88))
            }
            addAttachment(ComposerAttachment(kind: .image, name: "Photo \(index + 1).png", thumbnail: image, data: image.pngData()))
        }
        guard file else { return }
        addAttachment(ComposerAttachment(kind: .file, name: "build.log", data: Data(repeating: 0x61, count: 18_432)))
    }

    /// `count` characters of prose, sentences and paragraph breaks, for
    /// typing-cost captures of a long draft (`ComposerTypingLagUITests`).
    public static func demoProse(_ count: Int) -> String {
        let sentence = "The build fails on the second step when the cache is cold, so check the log and the screenshots before rerunning it. "
        var text = ""
        var index = 0
        while text.count < count {
            text += sentence
            index += 1
            if index % 4 == 0 { text += "\n\n" }
        }
        return String(text.prefix(count))
    }

    /// Demo drivers (`ws-terminal-reattach`): the session's link changes as a
    /// live session reports it. A state that is not attached holds until the
    /// next `demoConnection`, so the mock shell's output (which a live link
    /// reads as attached) does not end it.
    public func demoConnection(_ state: TerminalConnectionState) {
        demoHeldConnection = state.isAttached ? nil : state
        ingest(.connection(state))
    }

    /// Demo drivers (`ws-terminal-armed`): arms a modifier as its key-row tap does.
    public func demoArm(_ modifier: TerminalStickyModifiers.Modifier) {
        guard let surface = controller?.surface else { return }
        surface.tapSticky(modifier)
        sticky = surface.input.sticky
    }
    #endif

    func keyBar(_ key: KeyBarKey) {
        guard let surface = controller?.surface else { return }
        // Keys that leave the terminal (classic: paste, zoom, compose, hide)
        // first turn off an armed modifier, so it cannot linger unseen.
        let resetsModifiers: Bool = switch key {
        case .paste, .zoomOut, .zoomIn, .wide, .composer, .hideChrome, .launcher: true
        default: false
        }
        if resetsModifiers { surface.input.sticky.reset() }
        switch key {
        case .escape: surface.sendKey(usage: TerminalHIDUsage.escape)
        case .tab: surface.sendKey(usage: TerminalHIDUsage.tab)
        case .returnKey: surface.sendKey(usage: TerminalHIDUsage.enter)
        case .control, .alternate, .command, .shift:
            if let modifier = key.modifier { surface.tapSticky(modifier) }
        case .up: surface.sendKey(usage: TerminalHIDUsage.up)
        case .down: surface.sendKey(usage: TerminalHIDUsage.down)
        case .left: surface.sendKey(usage: TerminalHIDUsage.left)
        case .right: surface.sendKey(usage: TerminalHIDUsage.right)
        case .home: surface.sendKey(usage: TerminalHIDUsage.home)
        case .end: surface.sendKey(usage: TerminalHIDUsage.end)
        case .pageUp: surface.sendKey(usage: TerminalHIDUsage.pageUp)
        case .pageDown: surface.sendKey(usage: TerminalHIDUsage.pageDown)
        case .chord(let letter): surface.sendControl(letter)
        case .symbol(let text): surface.perform(surface.input.insertText(text))
        case .launcher(let launcher):
            // Typed with its Return in one go, as classic sent its bytes.
            surface.perform([.text(launcher.command)])
            if launcher.pressesReturn { surface.sendKey(usage: TerminalHIDUsage.enter) }
        case .paste: surface.paste(nil)
        case .zoomOut, .zoomIn: zoom(larger: key == .zoomIn)
        case .composer: composeKeyTapped()
        case .hideChrome: setChromeHidden(true)
        case .wide: setWide(!wideOutput)
        }
        sticky = surface.input.sticky
    }

    /// The key row's zoom keys: one point smaller or larger, saved as the
    /// terminal's font size (the surface follows the preference).
    private func zoom(larger: Bool) {
        let defaults = UserDefaults.standard
        let size = CmuxMobilePreferences.terminalFontSize(defaults)
        let next = TerminalFontZoom(sizes: CmuxMobilePreferences.terminalFontSizes).step(size, larger: larger)
        guard next != size else { return }
        defaults.set(next, forKey: CmuxMobilePreferences.Key.terminalFontSize)
    }

    /// The compose key (classic cmux iOS's `ComposerDockState`): open and
    /// focus, reveal and focus, or close only a shown, focused composer.
    func composeKeyTapped() {
        let dock = ComposerDockState(chromeHidden: chromeHidden, composerPresented: composerPresented,
                                     fieldFocused: composerFocused)
        switch dock.intentForComposeKeyTap() {
        case .openComposer, .revealAndFocusComposer:
            setChromeHidden(false)
            composerPresented = true
            focusComposer()
        case .closeComposer:
            // The keyboard stays up and keys go to the terminal (classic hands
            // first responder over instead of dropping the keyboard).
            composerPresented = false
            controller?.focusTerminal()
        }
        controller?.dockChanged()
    }

    /// Wide on or off: the page claims the wide grid (or the page's own
    /// again) and pans sideways while it is wider than the page.
    func setWide(_ on: Bool) {
        guard wideOutput != on else { return }
        wideOutput = on
        controller?.wideChanged()
    }

    /// Wide View, the dedicated view for wide output (Leo, 2026-11-23: "being
    /// able to flip [it] horizontally and actually have a dedicated view would
    /// help too"): Wide on and the key row, composer and keyboard away, so the
    /// grid has the whole page. A tap on the terminal brings them back (as
    /// Hide Toolbar); Wide stays on until its key turns it off.
    public func openWideView() {
        setWide(true)
        setChromeHidden(true)
    }

    /// Hide Toolbar: the key row, the composer and the keyboard go away until
    /// the next terminal tap. The composer and its draft stay as they were.
    func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        chromeHidden = hidden
        if hidden { controller?.hideKeyboard() }
        controller?.dockChanged()
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

    /// The top strip's tap: back to the last line sent from the phone, with
    /// a short scroll and a brief highlight on its row.
    public func jumpToLastSent() {
        controller?.jumpToLastSent()
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
    /// A file on the phone (a picked video's local copy, a picked file),
    /// streamed to the Mac at send without reading it whole.
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

    func payload() throws -> LinkUpload.Payload {
        if let data { return .data(data) }
        if let fileURL { return .file(fileURL) }
        throw Unreadable()
    }
}
#endif
