public import AppKit

/// The remote view's input surface for panes outside this module (Mac
/// Screen tabs): the same capture view, keyboard policy, release chord and
/// containment as the desktop pane, sending `RemoteInputEvent`s to `sink`.
@MainActor
public final class RemoteInputSurface {
    private let capture = RemoteInputCaptureView(frame: .zero)
    /// The controller holds its sink weakly; the owner keeps it alive.
    public weak var sink: (any RemoteViewInputSink)? {
        get { capture.controller.sink }
        set { capture.controller.sink = newValue }
    }

    /// The release chord took the keyboard back; a click on the surface ends it.
    public private(set) var isReleased = false
    private var wantsControl = false

    public init() {
        // The release chord (Control-Option-Escape) gives the keyboard back, and keeps it
        // back even when focus returns to the surface, until the next click on it.
        capture.controller.onReleaseKeyboard = { [weak self] in self?.release() }
        capture.onMouseDown = { [weak self] in self?.reengage() }
        capture.onFocusChange = { [weak self] focused in
            guard let self else { return }
            onFocusChange?(focused && !isReleased)
        }
    }

    /// Leaves the keyboard here until a click on the surface (as the release
    /// chord does): for a screen that just opened.
    public func waitForClick() { release() }

    private func release() {
        isReleased = true
        capture.controlMode = false
        capture.releaseKeyboard()
        onFocusChange?(false)
    }

    private func reengage() {
        guard isReleased else { return }
        isReleased = false
        capture.controlMode = wantsControl
        onFocusChange?(capture.window?.firstResponder === capture)
    }

    /// The view to place over the picture; it takes the keyboard on click.
    public var view: NSView { capture }

    /// Where the picture sits in `view` (stream pixels to points).
    public var geometry: () -> RemoteViewGeometry? {
        get { capture.geometry }
        set { capture.geometry = newValue }
    }

    /// Keyboard changes: true while the surface has the keyboard (focused and not released).
    public var onFocusChange: ((Bool) -> Void)?

    /// Control mode: input goes to the host while the surface is first responder.
    public var controlMode: Bool {
        get { wantsControl }
        set {
            wantsControl = newValue
            if !isReleased { capture.controlMode = newValue }
        }
    }

    /// Whether a click or scroll on the surface reaches it (and so the
    /// host). Off while the picture is not live: a click there neither takes
    /// the keyboard nor goes to the host.
    public var acceptsPointer: Bool {
        get { capture.acceptsPointer }
        set { capture.acceptsPointer = newValue }
    }

    /// cmux shortcut matcher: true keeps the chord in the viewer.
    public var isLocalShortcut: (NSEvent) -> Bool {
        get { capture.controller.isLocalShortcut }
        set { capture.controller.isLocalShortcut = newValue }
    }

    /// Gives the keyboard back to the viewer.
    public func releaseKeyboard() { capture.releaseKeyboard() }

    /// A key from the system shortcut tap: true when it was sent (the tap
    /// consumes it), false to let it go on to macOS.
    public func takeSystemKey(_ key: RemoteTapKey) -> Bool { capture.controller.takeSystemKey(key) }

    /// The window the surface is in.
    public var window: NSWindow? { capture.window }

    /// The surface has the keyboard now: first responder, in control mode, not released.
    public var hasKeyboard: Bool {
        wantsControl && !isReleased && capture.window?.firstResponder === capture
    }
}

extension RemoteMouseButton {
    /// The button of a mouse down or up. The event type names left and right
    /// (synthetic right clicks carry button number 0); other buttons come
    /// from the button number.
    public init?(event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: self = .left
        case .rightMouseDown, .rightMouseUp: self = .right
        default: self.init(appKitButtonNumber: event.buttonNumber)
        }
    }
}
