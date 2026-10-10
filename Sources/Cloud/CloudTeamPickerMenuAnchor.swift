import AppKit
import SwiftUI

/// Pops the team menu from the trigger's bottom-leading corner.
///
/// An AppKit menu rather than a SwiftUI `Menu`: the palette command and the
/// Open Team Picker shortcut must open the same menu programmatically, which
/// `Menu` cannot do, and a pull-down should track from mouse-down. The overlay
/// takes the pointer; keyboard and VoiceOver presses still reach the trigger
/// button beneath it, which requests the menu through `isPresented` like the
/// palette does. Because it takes the pointer, the button's own `onHover`
/// never fires, so the overlay reports hover through `isHovered`.
struct CloudTeamPickerMenuAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var isHovered: Bool
    let helpText: String
    /// Receives the anchor, so an item can place follow-up UI on the trigger's
    /// window once the menu closes.
    let makeMenu: @MainActor (CloudTeamPickerMenuAnchorView) -> NSMenu
    let onWillPresent: @MainActor () -> Void

    /// Creates the AppKit overlay that owns pointer tracking and menu input.
    func makeNSView(context: Context) -> CloudTeamPickerMenuAnchorView {
        let view = CloudTeamPickerMenuAnchorView()
        view.toolTip = helpText
        return view
    }

    /// Updates the overlay without changing the menu or hover ownership.
    func updateNSView(_ view: CloudTeamPickerMenuAnchorView, context: Context) {
        view.toolTip = helpText
        view.isRightToLeft = context.environment.layoutDirection == .rightToLeft
        view.isEnabled = context.environment.isEnabled
        view.makeMenu = makeMenu
        view.onWillPresent = onWillPresent
        view.onOpen = { isPresented = true }
        view.onDismiss = { isPresented = false }
        view.onHoverChange = { isHovered = $0 }
        view.syncPresentation(isPresented)
    }

    /// Cancels menu tracking when SwiftUI removes the overlay.
    static func dismantleNSView(_ view: CloudTeamPickerMenuAnchorView, coordinator: ()) {
        view.syncPresentation(false)
    }
}

/// Owns the menu's tracking session. `popUp` runs a modal event loop, so it is
/// never entered from a SwiftUI update pass or a main-queue block: programmatic
/// requests run from the next default-mode run-loop turn and wait until the
/// trigger has a window and a size. A request made while the trigger is
/// disabled is dropped, as a click would be.
final class CloudTeamPickerMenuAnchorView: NSView {
    var makeMenu: (@MainActor (CloudTeamPickerMenuAnchorView) -> NSMenu)?
    var onWillPresent: (@MainActor () -> Void)?
    var onOpen: (@MainActor () -> Void)?
    var onDismiss: (@MainActor () -> Void)?
    /// Called when the pointer enters or leaves the trigger. Reported whether
    /// or not the trigger is enabled; the trigger decides how to draw it.
    var onHoverChange: (@MainActor (Bool) -> Void)?
    var isRightToLeft = false
    var isEnabled = true

    /// How far above the requested point macOS 26 places a menu's frame
    /// (measured 5pt, the top padding of its rounded frame). Without it the
    /// menu covers the trigger's bottom edge.
    private static var menuFrameLift: CGFloat {
        if #available(macOS 26, *) { return 5 }
        return 0
    }

    private(set) var trackingMenu: NSMenu?
    private var afterDismissActions: [@MainActor () -> Void] = []
    private var isPresentationRequested = false
    private var isPresentationScheduled = false
    private var hoverTracking: NSTrackingArea?
    private var isPointerInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }

    /// Rebuilds the tracking area and reconciles it with the current pointer.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
        // Rebuilding the area can produce an exit for the old area even while
        // the pointer remains over this view. The window pointer is the source
        // of truth after every rebuild.
        syncPointerInside()
    }

    /// Records an enter from the active tracking area.
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        handleMouseEntered(from: event.trackingArea)
    }

    /// Records an exit from the active tracking area.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        handleMouseExited(from: event.trackingArea)
    }

    /// Applies an enter only when it belongs to the current tracking area.
    func handleMouseEntered(from trackingArea: NSTrackingArea?) {
        guard trackingArea == nil || trackingArea === hoverTracking else { return }
        setPointerInside(true)
    }

    /// Applies an exit only when it belongs to the current tracking area.
    func handleMouseExited(from trackingArea: NSTrackingArea?) {
        // An exit from the area removed by updateTrackingAreas is stale. The
        // replacement area has already reconciled against the current pointer.
        guard trackingArea == nil || trackingArea === hoverTracking else { return }
        setPointerInside(false)
    }

    private func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        onHoverChange?(inside)
    }

    /// The menu's tracking loop swallows enter and exit events, so hover is
    /// read from the pointer's position once the menu closes.
    private func syncPointerInside() {
        guard let window else {
            setPointerInside(false)
            return
        }
        let windowPoint = window.convertFromScreen(
            NSRect(origin: window.mouseLocationOutsideOfEventStream, size: .zero)
        ).origin
        let point = convert(windowPoint, from: nil)
        setPointerInside(bounds.contains(point))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, trackingMenu == nil else { return }
        isPresentationRequested = true
        onOpen?()
        present()
    }

    /// Ends hover before AppKit detaches the view from its current window.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            trackingMenu?.cancelTracking()
            // A window transition owns the pointer transition. Do this before
            // AppKit detaches the view so no stale exit can clear a reattached
            // view later.
            setPointerInside(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Reconciles hover and pending presentation after a window transition.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            setPointerInside(false)
        } else {
            syncPointerInside()
            presentIfRequested()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        presentIfRequested()
    }

    /// Runs `action` once the menu's tracking loop has returned, or right away
    /// when no menu is open. An item that opens a sheet uses this so the sheet
    /// never starts while the menu still holds the event loop.
    func afterDismiss(_ action: @escaping @MainActor () -> Void) {
        guard trackingMenu != nil else {
            action()
            return
        }
        afterDismissActions.append(action)
    }

    func syncPresentation(_ requested: Bool) {
        isPresentationRequested = requested
        if requested {
            presentIfRequested()
        } else {
            trackingMenu?.cancelTracking()
        }
    }

    private func presentIfRequested() {
        guard isPresentationRequested, trackingMenu == nil, !isPresentationScheduled else { return }
        isPresentationScheduled = true
        // A run-loop block, not DispatchQueue.main.async: the menu's nested
        // tracking loop cannot drain the main queue from inside a main-queue
        // callout, so every main-queue and main-actor job would wait for the
        // menu to close (the same starvation as #10788). `.default` also keeps
        // the open out of another menu's event-tracking loop.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPresentationScheduled = false
                guard self.isPresentationRequested else { return }
                guard self.isEnabled else {
                    self.isPresentationRequested = false
                    self.onDismiss?()
                    return
                }
                guard self.window != nil, !self.bounds.isEmpty else { return }
                self.present()
            }
        }
    }

    private func present() {
        guard trackingMenu == nil, let menu = makeMenu?(self) else { return }
        menu.minimumWidth = bounds.width
        menu.userInterfaceLayoutDirection = isRightToLeft ? .rightToLeft : .leftToRight
        trackingMenu = menu
        onWillPresent?()
        // Flipped coordinates: the menu's top-leading corner sits just below the
        // trigger, aligned with its leading edge in either layout direction.
        let origin = NSPoint(
            x: isRightToLeft ? bounds.width : 0,
            y: bounds.height + 2 + Self.menuFrameLift
        )
        _ = menu.popUp(positioning: nil, at: origin, in: self)
        trackingMenu = nil
        isPresentationRequested = false
        syncPointerInside()
        onDismiss?()
        let actions = afterDismissActions
        afterDismissActions.removeAll()
        actions.forEach { $0() }
    }
}
