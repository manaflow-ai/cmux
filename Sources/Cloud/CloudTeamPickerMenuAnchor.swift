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
    let makeMenu: @MainActor () -> NSMenu
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
/// never entered from a SwiftUI update pass: programmatic requests hop to the
/// next main-queue turn and wait until the trigger has a window and a size.
final class CloudTeamPickerMenuAnchorView: NSView {
    var makeMenu: (@MainActor () -> NSMenu)?
    var onWillPresent: (@MainActor () -> Void)?
    var onOpen: (@MainActor () -> Void)?
    var onDismiss: (@MainActor () -> Void)?
    var isRightToLeft = false
    var isEnabled = true {
        didSet { if isEnabled, !oldValue { presentIfRequested() } }
    }

    private(set) var trackingMenu: NSMenu?
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPresentationScheduled = false
            guard self.isPresentationRequested, self.window != nil,
                  !self.bounds.isEmpty, self.isEnabled else { return }
            self.present()
        }
    }

    private func present() {
        guard trackingMenu == nil, let menu = makeMenu?() else { return }
        menu.minimumWidth = bounds.width
        menu.userInterfaceLayoutDirection = isRightToLeft ? .rightToLeft : .leftToRight
        trackingMenu = menu
        onWillPresent?()
        // Flipped coordinates: the menu's top-leading corner sits just below the
        // trigger, aligned with its leading edge in either layout direction.
        let origin = NSPoint(x: isRightToLeft ? bounds.width : 0, y: bounds.height + 2)
        menu.popUp(positioning: nil, at: origin, in: self)
        trackingMenu = nil
        isPresentationRequested = false
        onDismiss?()
    }
}
