public import AppKit
public import SwiftUI

/// SwiftUI wrapper around an `NSTrackingArea`-driven hover relay.
///
/// SwiftUI's `.onHover` does not fire reliably for views layered inside an
/// AppKit-hosted popover (the notifications popover rows), so this representable
/// installs a click-through `NSView` whose only job is to report pointer
/// enter/exit through an `NSTrackingArea`. Clicks pass through to the SwiftUI
/// parent (which owns the tap gesture and accessibility action); only hover
/// crossings are relayed.
public struct HoverTrackingRepresentable: NSViewRepresentable {
    private let onChange: (Bool) -> Void

    /// Creates a hover relay.
    /// - Parameter onChange: Invoked with `true` when the pointer enters the
    ///   tracked bounds and `false` when it exits.
    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    public func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(onChange: onChange)
    }

    public func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onChange = onChange
    }
}

/// Click-through `NSView` that relays `NSTrackingArea` hover crossings.
///
/// Drives hover state from window mouse-tracking rather than `hitTest`, so it can
/// return `nil` from `hitTest` (passing clicks to the SwiftUI parent) while still
/// receiving `mouseEntered`/`mouseExited`.
public final class HoverTrackingNSView: NSView {
    /// Invoked with the current inside/outside hover state on every crossing.
    public var onChange: (Bool) -> Void
    private var trackingArea: NSTrackingArea?
    private var isInside: Bool = false

    /// Creates the relay view.
    /// - Parameter onChange: Invoked when the pointer enters or exits the view.
    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Pass clicks through to the SwiftUI parent (which owns the tap gesture and accessibility
    // action). Tracking areas keep working because they're driven by window mouse-tracking,
    // not by hitTest.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area

        // Sync current pointer state in case the pointer is already inside when the tracking
        // area is (re)installed — happens on first popover open or after layout changes.
        // updateTrackingAreas runs on the main thread, so dispatch synchronously; deferring
        // creates a race where mouseExited can fire before the queued sync-onChange(true) runs,
        // leaving the row stuck in the hovered state.
        if let window, window.isVisible {
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let mouseInView = convert(mouseInWindow, from: nil)
            let nowInside = bounds.contains(mouseInView)
            if nowInside != isInside {
                isInside = nowInside
                onChange(nowInside)
            }
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        if !isInside {
            isInside = true
            onChange(true)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if isInside {
            isInside = false
            onChange(false)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isInside {
            isInside = false
            onChange(false)
        }
    }
}
