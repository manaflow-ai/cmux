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

    public init() {
        // The release chord (Control-Option-Escape) gives the keyboard back.
        capture.controller.onReleaseKeyboard = { [weak capture] in capture?.releaseKeyboard() }
    }

    /// The view to place over the picture; it takes the keyboard on click.
    public var view: NSView { capture }

    /// Where the picture sits in `view` (stream pixels to points).
    public var geometry: () -> RemoteViewGeometry? {
        get { capture.geometry }
        set { capture.geometry = newValue }
    }

    /// Focus changes (true while the surface has the keyboard).
    public var onFocusChange: ((Bool) -> Void)? {
        get { capture.onFocusChange }
        set { capture.onFocusChange = newValue }
    }

    /// Control mode: input goes to the host while the surface is first responder.
    public var controlMode: Bool {
        get { capture.controlMode }
        set { capture.controlMode = newValue }
    }

    /// cmux shortcut matcher: true keeps the chord in the viewer.
    public var isLocalShortcut: (NSEvent) -> Bool {
        get { capture.controller.isLocalShortcut }
        set { capture.controller.isLocalShortcut = newValue }
    }

    /// Gives the keyboard back to the viewer.
    public func releaseKeyboard() { capture.releaseKeyboard() }
}
