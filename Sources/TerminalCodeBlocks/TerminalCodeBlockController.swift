import AppKit
import CmuxFoundation
import CmuxTerminal
import SwiftUI

/// Per-pane owner of terminal code block affordances.
///
/// - Hover: while the pointer is over a block the pane's agent wrote (found
///   through its transcript) or a literal fenced block on screen, a Copy /
///   Run pill sits at the block's top-right.
/// - Offered: blocks a process offered with `cmux code-block` show as cards
///   at the pane's top-right until dismissed.
/// - Run: opens a split to the right in the same directory and pastes the
///   command at its first prompt. It never presses Return and never touches
///   the agent's own pane; multi-line or long commands are shown in full
///   first and need a second click.
@MainActor
final class TerminalCodeBlockController {
    /// Offered cards kept per pane; older offers drop off.
    static let offeredLimit = 3
    /// How long a viewport read stays fresh while the pointer moves.
    private static let viewportRefreshInterval: TimeInterval = 0.25
    /// How often the transcript file is checked for new messages.
    private static let transcriptRefreshInterval: TimeInterval = 1.5
    /// Bytes read from the end of a transcript; plenty for the last turns.
    private static let transcriptTailBytes = 768 * 1024
    /// Right inset of pills and cards from the pane edge, clear of the scroller.
    private static let edgeInset: CGFloat = 14
    /// Delay between a new split's first prompt report and the paste, so the
    /// shell's line editor has turned bracketed paste on.
    private static let promptPasteDelay: TimeInterval = 0.25
    /// Deadline for a new split's shell to report its prompt.
    private static let promptPasteDeadline: TimeInterval = 6

    private weak var host: GhosttySurfaceScrollView?

    private var viewport: TerminalViewportRows?
    private var anchors: [TerminalCodeBlockAnchor] = []
    private var viewportReadAt = Date.distantPast

    private var transcriptEntries: [AgentTranscriptCodeBlockExtractor.Entry] = []
    private var transcriptStamp: TranscriptStamp?
    private var transcriptCheckedAt = Date.distantPast
    private var transcriptLoad: Task<Void, Never>?

    private var shownAnchor: TerminalCodeBlockAnchor?
    private var pillView: TerminalCodeBlockOverlayContainer?
    private var trayView: TerminalCodeBlockOverlayContainer?
    private var revalidateTimer: Timer?
    private var reviewPopover: NSPopover?
    private var reviewPopoverObserver: PopoverCloseObserver?

    private(set) var offered: [TerminalCodeBlock] = []
    private var pendingPaste: String?

    init(host: GhosttySurfaceScrollView) {
        self.host = host
    }

    // MARK: Pointer

    /// Called from the terminal view's mouse-moved and mouse-entered events.
    func pointerMoved(to point: NSPoint, in surfaceView: NSView) {
        guard NSEvent.pressedMouseButtons == 0 else {
            hidePill()
            return
        }
        refreshIfStale()
        update(forSurfacePoint: point, surfaceView: surfaceView)
    }

    /// Called when the pointer leaves the terminal view or the pill.
    func pointerExited() {
        revalidatePointer()
    }

    /// Returns the pill or a card when `point` (host coordinates) is on one,
    /// so the host's hit test routes clicks to it.
    func hitTest(hostPoint point: NSPoint) -> NSView? {
        for view in [pillView, trayView].compactMap({ $0 }) where view.superview === host {
            // NSView.hitTest takes a point in the view's superview (the host).
            if let hit = view.hitTest(point) {
                return hit
            }
        }
        return nil
    }

    private func revalidatePointer() {
        guard let host, let window = host.window else {
            hidePill()
            return
        }
        let surfaceView = host.surfaceView
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let hostPoint = host.convert(windowPoint, from: nil)
        if let pillView, pillView.frame.contains(hostPoint) { return }
        let surfacePoint = surfaceView.convert(windowPoint, from: nil)
        guard surfaceView.bounds.contains(surfacePoint) else {
            hidePill()
            return
        }
        refreshIfStale()
        update(forSurfacePoint: surfacePoint, surfaceView: surfaceView)
    }

    private func update(forSurfacePoint point: NSPoint, surfaceView: NSView) {
        guard let host, let viewport, let geometry = RowGeometry(viewport: viewport, surfaceView: surfaceView) else {
            hidePill()
            return
        }
        let hostPoint = surfaceView.convert(point, to: host)
        if let pillView, pillView.frame.contains(hostPoint) { return }
        let row = geometry.row(atTopY: surfaceView.bounds.height - point.y)
        let resolver = TerminalCodeBlockAnchorResolver()
        let hovered = anchors.first { anchor in
            let pillRow = resolver.pillRow(for: anchor, rows: viewport.rows)
            return (min(pillRow, anchor.rows.lowerBound)...anchor.rows.upperBound).contains(row)
        }
        guard let hovered else {
            hidePill()
            return
        }
        showPill(for: hovered, row: resolver.pillRow(for: hovered, rows: viewport.rows), geometry: geometry)
    }

    // MARK: Data

    private func refreshIfStale() {
        let now = Date()
        if now.timeIntervalSince(transcriptCheckedAt) > Self.transcriptRefreshInterval {
            transcriptCheckedAt = now
            loadTranscriptIfChanged()
        }
        guard now.timeIntervalSince(viewportReadAt) > Self.viewportRefreshInterval else { return }
        viewportReadAt = now
        recomputeAnchors()
    }

    private func recomputeAnchors() {
        guard let terminalSurface = host?.surfaceView.terminalSurface else {
            viewport = nil
            anchors = []
            return
        }
        // Row-by-row reads cost one runtime call per row. With nothing offered
        // and no agent transcript, only a literal fence can match, so one
        // whole-viewport read decides whether the row read is needed.
        if offered.isEmpty, transcriptEntries.isEmpty {
            let visible = terminalSurface.readText(region: .viewport) ?? ""
            guard visible.contains("```") || visible.contains("~~~") else {
                viewport = nil
                anchors = []
                return
            }
        }
        guard let rows = terminalSurface.readViewportRows() else {
            viewport = nil
            anchors = []
            return
        }
        viewport = rows
        anchors = TerminalCodeBlockAnchorResolver().anchors(
            rows: rows.rows,
            offered: offered,
            transcript: transcriptEntries
        )
    }

    private func loadTranscriptIfChanged() {
        guard transcriptLoad == nil,
              let surfaceID = host?.surfaceView.terminalSurface?.id,
              let service = TerminalController.shared.agentChatTranscriptService,
              let path = service.registry.liveSession(surfaceID: surfaceID.uuidString)?.transcriptPath,
              !path.isEmpty else {
            if transcriptLoad == nil { transcriptEntries = [] }
            return
        }
        let previous = transcriptStamp
        let tailBytes = Self.transcriptTailBytes
        transcriptLoad = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> (TranscriptStamp, [AgentTranscriptCodeBlockExtractor.Entry])? in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.uint64Value,
                      let modified = attributes[.modificationDate] as? Date else { return nil }
                let stamp = TranscriptStamp(path: path, size: size, modified: modified)
                guard stamp != previous,
                      let handle = FileHandle(forReadingAtPath: path) else { return nil }
                defer { try? handle.close() }
                let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
                guard (try? handle.seek(toOffset: offset)) != nil,
                      let data = try? handle.readToEnd() else { return nil }
                return (stamp, AgentTranscriptCodeBlockExtractor().entries(fromJSONLTail: data))
            }.value
            guard let self else { return }
            self.transcriptLoad = nil
            guard let loaded else { return }
            self.transcriptStamp = loaded.0
            self.transcriptEntries = loaded.1
            self.viewportReadAt = .distantPast
            if self.shownAnchor != nil { self.revalidatePointer() }
        }
    }

    // MARK: Pill

    private func showPill(for anchor: TerminalCodeBlockAnchor, row: Int, geometry: RowGeometry) {
        guard let host else { return }
        let surfaceView = host.surfaceView
        if shownAnchor?.block.id != anchor.block.id || pillView == nil {
            pillView?.removeFromSuperview()
            let block = anchor.block
            let container = TerminalCodeBlockOverlayContainer()
            container.onPointerExit = { [weak self] in self?.pointerExited() }
            let hosting = NSHostingView(
                rootView: TerminalCodeBlockPill(
                    block: block,
                    onCopy: { [weak self] in self?.copy(block) },
                    onRun: { [weak self, weak container] in
                        guard let container else { return }
                        self?.run(block, from: container)
                    }
                )
            )
            container.install(hosting)
            host.addSubview(container)
            pillView = container
        }
        shownAnchor = anchor
        guard let pillView else { return }
        let size = pillView.fittingSize
        let centerTop = geometry.rowTop(row) + geometry.pitch / 2
        let center = surfaceView.convert(
            NSPoint(x: surfaceView.bounds.maxX, y: surfaceView.bounds.height - centerTop),
            to: host
        )
        pillView.frame = NSRect(
            x: center.x - size.width - Self.edgeInset,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        startRevalidating()
    }

    private func hidePill() {
        guard reviewPopover == nil else { return }
        shownAnchor = nil
        pillView?.removeFromSuperview()
        pillView = nil
        stopRevalidating()
    }

    /// While a pill is up, output can scroll the block away without any
    /// pointer event; re-check on a slow timer.
    private func startRevalidating() {
        guard revalidateTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidatePointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revalidateTimer = timer
    }

    private func stopRevalidating() {
        revalidateTimer?.invalidate()
        revalidateTimer = nil
    }

    // MARK: Offered blocks

    /// Adds a block offered through the socket, newest first.
    func offer(_ block: TerminalCodeBlock) {
        offered.removeAll { $0.id == block.id }
        offered.insert(block, at: 0)
        if offered.count > Self.offeredLimit { offered.removeLast(offered.count - Self.offeredLimit) }
        viewportReadAt = .distantPast
        layoutTray()
    }

    /// Removes offered blocks: one by id, or all.
    func dismissOffered(id: String? = nil) {
        if let id {
            offered.removeAll { $0.id == id }
        } else {
            offered.removeAll()
        }
        viewportReadAt = .distantPast
        layoutTray()
    }

    /// Positions the offered cards; call after the pane resizes.
    func layoutTray() {
        guard let host else { return }
        guard !offered.isEmpty else {
            trayView?.removeFromSuperview()
            trayView = nil
            return
        }
        let container: TerminalCodeBlockOverlayContainer
        if let trayView {
            container = trayView
        } else {
            container = TerminalCodeBlockOverlayContainer()
            host.addSubview(container)
            trayView = container
        }
        let hosting = NSHostingView(
            rootView: TerminalCodeBlockTray(
                blocks: offered,
                onCopy: { [weak self] block in self?.copy(block) },
                onRun: { [weak self, weak container] block in
                    guard let container else { return }
                    self?.run(block, from: container)
                },
                onDismiss: { [weak self] block in self?.dismissOffered(id: block.id) }
            )
        )
        container.install(hosting)
        let surfaceView = host.surfaceView
        let size = container.fittingSize
        let topRight = surfaceView.convert(NSPoint(x: surfaceView.bounds.maxX, y: surfaceView.bounds.maxY), to: host)
        let isFlipped = host.isFlipped
        container.frame = NSRect(
            x: topRight.x - size.width - Self.edgeInset,
            y: isFlipped ? topRight.y + 10 : topRight.y - size.height - 10,
            width: size.width,
            height: size.height
        ).integral
    }

    // MARK: Actions

    private func copy(_ block: TerminalCodeBlock) {
        _ = GhosttyApp.terminalPasteboard.writeString(block.text, to: .general)
    }

    private func run(_ block: TerminalCodeBlock, from anchorView: NSView) {
        let policy = TerminalCodeBlockRunPolicy()
        let text = policy.pasteText(block.text)
        guard block.isRunnable, !text.isEmpty else { return }
        guard policy.requiresReview(block.text) else {
            openSplit(pasting: text)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: TerminalCodeBlockReviewView(
                block: block,
                onConfirm: { [weak self, weak popover] in
                    popover?.performClose(nil)
                    self?.openSplit(pasting: text)
                },
                onCancel: { [weak popover] in popover?.performClose(nil) }
            )
        )
        let observer = PopoverCloseObserver { [weak self] in
            self?.reviewPopover = nil
            self?.reviewPopoverObserver = nil
            self?.revalidatePointer()
        }
        popover.delegate = observer
        reviewPopoverObserver = observer
        reviewPopover = popover
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    /// Opens a split to the right of this pane, in its directory, and pastes
    /// `text` at the new shell's first prompt. Falls back to the clipboard
    /// when no local split can be made (remote tmux mirrors, closed panes).
    private func openSplit(pasting text: String) {
        guard let terminalSurface = host?.surfaceView.terminalSurface else { return }
        let surfaceID = terminalSurface.id
        let tabID = terminalSurface.tabId
        guard let app = AppDelegate.shared,
              app.remoteTmuxController?.isMirrorPaneSurface(surfaceID) != true,
              let manager = app.tabManagerFor(tabId: tabID) ?? app.tabManager,
              let panel = manager.createSplitOutcome(tabId: tabID, surfaceId: surfaceID, direction: .right).panel else {
            _ = GhosttyApp.terminalPasteboard.writeString(text, to: .general)
            NSSound.beep()
            return
        }
        panel.surface.hostedView.codeBlocks.pasteAtFirstPrompt(text)
    }

    // MARK: Paste into a new split

    /// Holds `text` until this pane's shell reports its first prompt.
    ///
    /// A shell pastes a newline as Return unless its line editor has turned
    /// bracketed paste on, so a multi-line command waits for the prompt. When
    /// the shell never reports one (no cmux shell integration) a one-line
    /// command is still typed, since it contains no newline; a multi-line one
    /// goes to the clipboard instead, where Cmd+V gets the terminal's own
    /// paste protection.
    func pasteAtFirstPrompt(_ text: String) {
        pendingPaste = text
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptPasteDeadline) { [weak self] in
            self?.deliverPendingPaste(promptConfirmed: false)
        }
    }

    /// Called when this pane's shell reports an idle prompt.
    func shellDidReportPrompt() {
        guard pendingPaste != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.promptPasteDelay) { [weak self] in
            self?.deliverPendingPaste(promptConfirmed: true)
        }
    }

    private func deliverPendingPaste(promptConfirmed: Bool) {
        guard let text = pendingPaste else { return }
        pendingPaste = nil
        guard let terminalSurface = host?.surfaceView.terminalSurface else { return }
        if promptConfirmed || !text.contains("\n") {
            _ = terminalSurface.sendTextResult(text)
        } else {
            _ = GhosttyApp.terminalPasteboard.writeString(text, to: .general)
        }
    }
}

/// Maps between grid rows and the surface view's vertical positions.
private struct RowGeometry {
    /// Baseline of row 0, points from the view's top.
    let firstBaseline: CGFloat
    /// Row height in points.
    let pitch: CGFloat
    /// Fraction of a row above its baseline (typical monospace ascent).
    static let ascentFraction: CGFloat = 0.78

    init?(viewport: TerminalViewportRows, surfaceView: NSView) {
        let known = viewport.rowBaselines.enumerated().compactMap { index, baseline in
            baseline.map { (index, CGFloat($0)) }
        }
        let scale = surfaceView.window?.backingScaleFactor ?? 2
        var pitch = CGFloat(viewport.cellHeightPixels) / max(scale, 1)
        if let first = known.first, let last = known.last, last.0 > first.0 {
            pitch = (last.1 - first.1) / CGFloat(last.0 - first.0)
        }
        guard pitch > 0, let anchor = known.first else { return nil }
        self.pitch = pitch
        self.firstBaseline = anchor.1 - CGFloat(anchor.0) * pitch
    }

    func rowTop(_ row: Int) -> CGFloat {
        firstBaseline + CGFloat(row) * pitch - Self.ascentFraction * pitch
    }

    func row(atTopY y: CGFloat) -> Int {
        Int(((y - rowTop(0)) / pitch).rounded(.down))
    }
}

/// Identifies the transcript contents last parsed.
private struct TranscriptStamp: Equatable, Sendable {
    let path: String
    let size: UInt64
    let modified: Date
}

/// Clears the controller's popover reference when the review closes.
@MainActor
private final class PopoverCloseObserver: NSObject, NSPopoverDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
    }
}

/// Hosts a pill or card over the terminal and reports when the pointer
/// leaves it.
final class TerminalCodeBlockOverlayContainer: NSView {
    var onPointerExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    func install(_ content: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = bounds
        addSubview(content)
        frame.size = content.fittingSize
        content.frame = bounds
    }

    override var fittingSize: NSSize {
        subviews.first?.fittingSize ?? .zero
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerExit?()
    }
}
