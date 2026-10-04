public import AppKit

/// The named layers above the content, bottom to top: content (page
/// windows) < pane chrome < `.pane` overlays < the sidebar (an occluder) <
/// `.window` overlays < `.modal` overlays.
public enum OverlayLayer: Equatable, Sendable {
    /// Inside one pane: clipped to `clip` (window coordinates) minus every
    /// occluder (the sidebar).
    case pane(clip: NSRect)
    case window
    case modal
}

/// How an overlay presented by `WindowOverlayHost` behaves.
public struct OverlayOptions: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Near the anchor, never takes the mouse (a tooltip).
        case tooltip
        /// Next to the anchor (a hover card, a suggestion list, page info).
        case popover
        /// Bottom center of the window (or of the anchor).
        case toast
        /// At the anchor's bottom-left corner.
        case menu
        /// At the anchor's origin, never takes the mouse.
        case dragGhost
        /// Centered in the window (or on the anchor).
        case dialog
    }

    public var kind: Kind
    /// Window coordinates (AppKit, bottom-left origin). Nil: the kind's default place.
    public var anchor: NSRect?
    /// Focus trap: the overlay takes the keyboard, Tab cycles inside it, and
    /// the previous first responder comes back when it is dismissed. Clicks
    /// anywhere in the window are blocked, or only inside `modalRegion` when
    /// it is set (a tab dialog: a click outside gives the keyboard back to
    /// the window, a click inside takes it again).
    public var isModal: Bool
    /// Escape (`cancelOperation`) dismisses it.
    public var dismissOnEscape: Bool
    /// A scrim over the whole window, pages included.
    public var dimsContent: Bool
    /// The overlay itself never takes the mouse (clicks reach what is below).
    public var passesThroughClicks: Bool
    /// Window coordinates: mouse input inside this rect is blocked (a
    /// tab-region modal), the rest of the window stays usable.
    public var modalRegion: NSRect?
    /// Nil: `.modal` for dialogs, `.window` otherwise (`effectiveLayer`).
    public var layer: OverlayLayer?

    public var effectiveLayer: OverlayLayer { layer ?? (kind == .dialog ? .modal : .window) }

    public init(kind: Kind, anchor: NSRect? = nil, isModal: Bool = false, dismissOnEscape: Bool = false,
                dimsContent: Bool = false, passesThroughClicks: Bool? = nil, modalRegion: NSRect? = nil,
                layer: OverlayLayer? = nil) {
        self.layer = layer
        self.kind = kind
        self.anchor = anchor
        self.isModal = isModal
        self.dismissOnEscape = dismissOnEscape
        self.dimsContent = dimsContent
        self.passesThroughClicks = passesThroughClicks ?? (kind == .tooltip || kind == .dragGhost)
        self.modalRegion = modalRegion
    }

    /// A tooltip at `anchor`.
    public static func tooltip(at anchor: NSRect) -> OverlayOptions { OverlayOptions(kind: .tooltip, anchor: anchor) }

    /// A modal dialog: focus trap, Escape dismisses, scrim.
    public static func dialog(dimsContent: Bool = true) -> OverlayOptions {
        OverlayOptions(kind: .dialog, isModal: true, dismissOnEscape: true, dimsContent: dimsContent)
    }
}

/// One presented overlay. Dismissing it (or its host closing) calls `onDismiss` once.
@MainActor
public final class OverlayHandle {
    public var onDismiss: (() -> Void)?
    public private(set) var isDismissed = false
    weak var host: WindowOverlayHost?
    let id: Int
    /// The clip of a `.pane` overlay (its pane minus the occluders).
    var clipView: OverlayClipView?
    /// Clears the host's region cache when the content resizes on its own.
    var frameObserver: (any NSObjectProtocol)?
    var options: OverlayOptions
    let content: NSView

    init(id: Int, content: NSView, options: OverlayOptions, host: WindowOverlayHost) {
        self.id = id
        self.content = content
        self.options = options
        self.host = host
    }

    /// Moves the overlay to a new anchor (window coordinates).
    public func update(anchor: NSRect) {
        options.anchor = anchor
        host?.layout(self)
    }

    /// Moves the overlay and its blocked region (a tab dialog after a tab resize).
    public func update(anchor: NSRect, modalRegion: NSRect?) {
        options.anchor = anchor
        options.modalRegion = modalRegion
        host?.layout(self)
        host?.onBlockingChange?()
    }

    /// A `.pane` overlay's pane moved or resized (window coordinates).
    public func update(paneClip clip: NSRect) {
        guard case .pane = options.effectiveLayer else { return }
        options.layer = .pane(clip: clip)
        host?.layout(self)
    }

    public func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        host?.remove(self)
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}
