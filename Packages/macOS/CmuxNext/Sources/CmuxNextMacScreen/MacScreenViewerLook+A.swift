import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
import Observation

/// Look A, "Quiet glass, picture first" (Leo 2026-11-21: "we need far better ui/ux for our shit! our screen shared scren
/// look slike ass"): the picture takes the whole pane, letterboxed on the window's material; one 28 pt glass toolbar floats
/// over its top and fades out while live and idle; View | Control is a segmented control; control shows as a focus edge
/// and a corner pill; transient states are a small mark and one line, lasting ones a raised label with one primary button.
extension MacScreenViewerStyle {
    static var lookA: MacScreenViewerStyle {
        var style = MacScreenViewerStyle.current
        style.toolbarPlacement = .floating
        style.toolbarInset = Metrics.space4
        style.toolbarFilled = false
        style.toolbarRowHeight = MacScreenLookA.toolbarHeight
        style.toolbarCornerRadius = MacScreenLookA.toolbarHeight / 2 // radius-allow: the floating toolbar is a capsule
        style.toolbarSurface = { MacScreenLookA.glass(cornerRadius: $0) }
        style.toolbarScopeSegments = true
        style.toolbarAutoHide = true
        style.backdrop = .page
        style.pictureMarks = true
        style.outageKeepsPicture = true
        style.cardQuietTransient = true
        style.cardCornerRadius = Metrics.surfaceCornerRadius
        return style
    }
}

/// Look A's sizes and its glass.
@MainActor
enum MacScreenLookA {
    static let toolbarHeight: CGFloat = 28
    /// How long a live, idle toolbar stays before it fades out.
    static let idleDelay = Duration.milliseconds(2500)
    /// How long a stall lasts before the quiet Reconnecting pill shows (a short blip shows nothing).
    static let outageMarkDelay = Duration.milliseconds(1000)
    /// The pane's top band that brings the toolbar back, at least.
    static let revealHeight: CGFloat = 40
    /// While this Mac controls the picture, only the pane's top edge brings the toolbar back (as a full-screen Mac's
    /// menu bar comes back), so the remote menu bar under the toolbar takes the pointer and its clicks.
    static let controlRevealHeight: CGFloat = 4
    static let edgeWidth: CGFloat = 2

    /// The chrome glass behind a floating toolbar or a pill: transient neutral glass, not interactive.
    static func glass(cornerRadius: CGFloat) -> NSView {
        let surface = Glass.makeOverlayPanel(cornerRadius: cornerRadius, interactive: false, tone: .neutralGlass(.transient))
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        return surface
    }
}

extension MacScreenCard {
    /// A quiet card's loading mark: small and faint, as the terminal's status banner draws its own.
    static let quietMarkSide: CGFloat = 14
    static let quietMarkAlpha: CGFloat = 0.4

    /// A state that passes on its own (connecting, waiting): no action is asked of the person.
    var isTransient: Bool {
        switch self {
        case .connecting, .waitingForPicture, .hubRequesting, .hubWaiting: true
        default: false
        }
    }
}

extension MacScreenColors {
    /// No fill: a quiet card has no surface.
    var noFill: NSColor { .clear }
}

extension MacScreenPaneModel {
    /// A live session stalled with its last picture still up: an outage, not an error.
    var outageOverPicture: Bool { isLive && hasFrame && session?.isStalled == true }
}

/// The layer over the picture, a sibling of the video view (never inside it): fades a floating toolbar out while live and
/// idle, back in at the pane's top edge (``MacScreenViewerStyle/toolbarAutoHide``), and draws the picture marks
/// (``MacScreenViewerStyle/pictureMarks``). It takes no clicks; the input surface's mapping is untouched.
@MainActor
final class MacScreenViewerOverlay: MacScreenThemedView {
    private enum Mark { case none, controlling, viewOnly, reconnecting }

    private let model: MacScreenPaneModel
    /// Follows the model (``ObservationStream``); ends once the view is gone.
    private var watch: Task<Void, Never>?
    private let toolbar: MacScreenToolbarView
    private let edge = CALayer()
    private let pill = MacScreenPictureMark()
    private let hideTimer = DemandTimer(owner: "mac-screen.toolbar-hide")
    private let outageTimer = DemandTimer(owner: "mac-screen.outage-mark")
    private var tracking: NSTrackingArea?
    private(set) var revealZone = CGRect.zero
    private var toolbarRect = CGRect.zero
    private var paneBounds = CGRect.zero
    private var picture = CGRect.zero
    private var pointerAtTop = false
    private var toolbarShown = true
    private var outageMarkDue = false
    private var mark = Mark.none

    init(model: MacScreenPaneModel, toolbar: MacScreenToolbarView) {
        self.model = model
        self.toolbar = toolbar
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        edge.borderWidth = MacScreenLookA.edgeWidth
        edge.isHidden = true
        layer?.addSublayer(edge)
        pill.isHidden = true
        addSubview(pill)
        track()
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The pane lays the overlay over itself: the picture's rect (for the marks) and the toolbar's (for its reveal band).
    func place(picture: CGRect, toolbar: CGRect, in bounds: CGRect) {
        if frame != bounds { frame = bounds }
        toolbarRect = toolbar
        paneBounds = bounds
        let zoneChanged = syncRevealZone()
        guard picture != self.picture || zoneChanged else { return }
        self.picture = picture
        needsLayout = true
    }

    /// The band that brings the toolbar back: the toolbar's rows and a margin, or only the top edge while this Mac
    /// controls a live picture (the remote Mac's menu bar is under the toolbar). True when it changed.
    @discardableResult
    private func syncRevealZone() -> Bool {
        let controlling = model.isLive && model.hasFrame && !model.viewOnly
        let height = controlling ? MacScreenLookA.controlRevealHeight : max(MacScreenLookA.revealHeight, toolbarRect.maxY + Metrics.space4)
        let zone = CGRect(x: 0, y: 0, width: paneBounds.width, height: height)
        guard zone != revealZone else { return false }
        revealZone = zone
        updateTrackingAreas()
        return true
    }

    override func colorsChanged() {
        edge.borderColor = colors.focus.cgColor
        super.colorsChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hideTimer.cancel()
            outageTimer.cancel()
            pointerAtTop = false
        }
        sync()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard model.viewerLook.style.toolbarAutoHide, !revealZone.isEmpty else { return }
        let area = NSTrackingArea(rect: revealZone, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerAtTop = true
        sync()
    }

    override func mouseExited(with event: NSEvent) {
        pointerAtTop = false
        sync()
    }

    // MARK: State

    private func track() {
        // At once for the first frame (the gallery draws in this turn), then on each change.
        updateTrackingAreas()
        sync()
        let model = model
        watch = Task { [weak self] in
            for await _ in ObservationStream({
                _ = model.viewerLook
                _ = model.isLive
                _ = model.card
                _ = model.hasFrame
                _ = model.session?.isStalled
                _ = model.viewOnly
                _ = model.capturesKeyboard
            }) {
                guard let self else { return }
                // The look may have turned auto-hide on or off; taking or giving up control moves the reveal band.
                if !syncRevealZone() { updateTrackingAreas() }
                sync()
            }
        }
    }

    /// The toolbar stays while the pane is not live, a card asks something, or the pointer is at the top; otherwise it
    /// fades out after ``MacScreenLookA/idleDelay`` (armed only in the key window: nothing runs in a gallery or test).
    private func sync() {
        let style = model.viewerLook.style
        let outage = model.outageOverPicture
        let pinned = !style.toolbarAutoHide || !model.isLive || (model.card != nil && !outage) || pointerAtTop
        if pinned {
            hideTimer.cancel()
            showToolbar(true)
        } else if toolbarShown, !hideTimer.isScheduled, window?.isKeyWindow == true {
            scheduleHide()
        }
        if style.pictureMarks, outage, window != nil {
            if !outageMarkDue {
                outageTimer.scheduleIfIdle(after: MacScreenLookA.outageMarkDelay) { @MainActor [weak self] in
                    self?.outageMarkDue = true
                    self?.sync()
                }
            }
        } else {
            outageTimer.cancel()
            outageMarkDue = false
        }
        let next = nextMark(style, outage: outage)
        if next != mark {
            mark = next
            needsLayout = true
        }
    }

    private func nextMark(_ style: MacScreenViewerStyle, outage: Bool) -> Mark {
        guard style.pictureMarks, model.isLive, model.hasFrame else { return .none }
        if outage { return outageMarkDue ? .reconnecting : .none }
        if model.card != nil { return .none }
        if model.viewOnly { return .viewOnly }
        return model.capturesKeyboard ? .controlling : .none
    }

    private func scheduleHide() {
        hideTimer.schedule(after: MacScreenLookA.idleDelay) { @MainActor [weak self] in
            guard let self else { return }
            // A toolbar menu open, or the pointer back at the top unseen (the window was not key): keep it a while longer.
            if RunLoop.main.currentMode == .eventTracking || pointerInZone {
                scheduleHide()
                return
            }
            showToolbar(false)
        }
    }

    /// The pointer is in the reveal band, or on the shown toolbar (the control band is only the top edge).
    private var pointerInZone: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return revealZone.contains(point) || (toolbarShown && toolbarRect.contains(point))
    }

    /// Fades the toolbar (alpha only, no layout change); a faded one is hidden so clicks reach the picture.
    private func showToolbar(_ shown: Bool) {
        guard shown != toolbarShown else { return }
        toolbarShown = shown
        let toolbar = toolbar
        if shown {
            toolbar.autoHidden = false
            Motion.overlays.animate(.fadeIn, in: toolbar, { toolbar.animator().alphaValue = 1 })
        } else {
            Motion.overlays.animate(.fadeOut, in: toolbar, { toolbar.animator().alphaValue = 0 }, completion: { [weak self] in
                guard let self, !toolbarShown else { return }
                self.toolbar.autoHidden = true
            })
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Inside the picture's rect, so the picture and the pointer mapping never move.
        edge.frame = picture
        edge.cornerRadius = model.viewerLook.style.pictureCornerRadius
        edge.cornerCurve = .continuous
        edge.isHidden = mark != .controlling || picture.isEmpty
        CATransaction.commit()
        switch mark {
        case .none: pill.isHidden = true
        case .controlling: pill.show(.controlling)
        case .viewOnly: pill.show(.viewOnly)
        case .reconnecting: pill.show(.reconnecting)
        }
        guard !pill.isHidden, !picture.isEmpty else { pill.isHidden = true; return }
        let size = pill.fittingSize
        let inset = Metrics.space4
        pill.frame = CGRect(x: picture.maxX - inset - size.width, y: picture.maxY - inset - size.height,
                            width: size.width, height: size.height).integral
    }
}
