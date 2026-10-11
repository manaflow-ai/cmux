import AppKit
import SwiftUI

/// Pops the team menu from the trigger's bottom-leading corner.
///
/// An AppKit menu rather than a SwiftUI `Menu`: the palette command and the
/// Open Team Picker shortcut must open the same menu programmatically, which
/// `Menu` cannot do, and a pull-down should track from mouse-down. The overlay
/// takes the pointer; keyboard and VoiceOver presses still reach the trigger
/// button beneath it, which requests the menu through `isPresented` like the
/// palette does.
struct CloudTeamPickerMenuAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let helpText: String
    /// Receives the anchor, so an item can place follow-up UI on the trigger's
    /// window once the menu closes.
    let makeMenu: @MainActor (CloudTeamPickerMenuAnchorView) -> NSMenu
    let onWillPresent: @MainActor () -> Void

    func makeNSView(context: Context) -> CloudTeamPickerMenuAnchorView {
        let view = CloudTeamPickerMenuAnchorView()
        view.toolTip = helpText
        return view
    }

    func updateNSView(_ view: CloudTeamPickerMenuAnchorView, context: Context) {
        view.toolTip = helpText
        view.isRightToLeft = context.environment.layoutDirection == .rightToLeft
        view.isEnabled = context.environment.isEnabled
        view.makeMenu = makeMenu
        view.onWillPresent = onWillPresent
        view.onOpen = { isPresented = true }
        view.onDismiss = { isPresented = false }
        view.syncPresentation(isPresented)
    }

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

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, trackingMenu == nil else { return }
        isPresentationRequested = true
        onOpen?()
        present()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            trackingMenu?.cancelTracking()
        } else {
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
        onDismiss?()
        let actions = afterDismissActions
        afterDismissActions.removeAll()
        actions.forEach { $0() }
    }
}
