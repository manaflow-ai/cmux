import AppKit
import SwiftUI

/// A thin, invisible strip along the window's leading edge that reports when
/// the pointer rests in it.
///
/// Deliberately an `NSTrackingArea` rather than a hit-test or an event monitor.
/// `WindowTerminalHostView.hitTest()` is on the typing-latency path (see
/// CLAUDE.md) and every keystroke passes through it; a tracking area is
/// serviced by AppKit's own mouse-moved plumbing and costs nothing while the
/// pointer is elsewhere. The strip also declines to become first responder and
/// passes clicks through, so it can never eat a click meant for the terminal
/// underneath.
struct SidebarPeekEdgeTrackingView: NSViewRepresentable {
    /// Width of the sensitive strip.
    let width: CGFloat
    /// Whether tracking is live. False removes the tracking area entirely
    /// rather than ignoring callbacks, so a docked sidebar costs nothing.
    let isEnabled: Bool
    /// Called when the pointer enters the strip.
    let onEnter: () -> Void
    /// Called when the pointer leaves the strip.
    let onExit: () -> Void

    func makeNSView(context: Context) -> EdgeStripView {
        let view = EdgeStripView()
        view.onEnter = onEnter
        view.onExit = onExit
        view.isTrackingEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: EdgeStripView, context: Context) {
        nsView.onEnter = onEnter
        nsView.onExit = onExit
        nsView.isTrackingEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: EdgeStripView, coordinator: ()) {
        nsView.isTrackingEnabled = false
    }

    /// The strip itself.
    final class EdgeStripView: NSView {
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?

        var isTrackingEnabled = true {
            didSet {
                guard isTrackingEnabled != oldValue else { return }
                rebuildTrackingArea()
            }
        }

        private var trackingArea: NSTrackingArea?
        private var isInside = false

        override var acceptsFirstResponder: Bool { false }

        /// Transparent to clicks: the strip observes the pointer, it does not
        /// capture it. Without this the leading column of the terminal would
        /// stop responding to text selection.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            rebuildTrackingArea()
        }

        override func mouseEntered(with event: NSEvent) {
            guard isTrackingEnabled, !isInside else { return }
            isInside = true
            onEnter?()
        }

        override func mouseExited(with event: NSEvent) {
            guard isInside else { return }
            isInside = false
            onExit?()
        }

        private func rebuildTrackingArea() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
                self.trackingArea = nil
            }
            // Leaving the strip while tracking is switched off would otherwise
            // never deliver `mouseExited`, stranding the machine mid-arm.
            if isInside, !isTrackingEnabled {
                isInside = false
                onExit?()
            }
            guard isTrackingEnabled, !bounds.isEmpty else { return }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }
    }
}
