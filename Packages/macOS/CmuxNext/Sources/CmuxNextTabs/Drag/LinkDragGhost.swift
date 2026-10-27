package import AppKit
package import CmuxNextDesign

/// The pill that follows the pointer while a link is dragged out of a chat (``LinkDragSession``):
/// the link's host and path on glass, in a borderless panel that ignores the mouse and floats
/// above every window. It only moves; the layout's own drop preview shows where the link lands.
///
/// With `motion.renderServer` on (``rendersOnServer``) the pill follows Chrome's attached drag, as the
/// tab drag ghost does (p03-rendering-035; chrome/browser/ui/views/tabs/tab_drag_controller.cc: an
/// attached drag moves views inside the source widget, only a detached one gets a window of its own).
/// Inside the source window it is a view in that window's overlay host, moved per pointer event by one
/// view origin with no window call; the panel shows it only outside, or where the window does not show
/// all of it in front.
package final class LinkDragGhost {
    package let panel: NSPanel
    /// The pill itself: its glass and its label.
    package let pill: NSView
    /// `motion.renderServer`, read once for the drag.
    package let rendersOnServer: Bool
    /// The window the drag started in: its overlay holds the pill while the pill fits there.
    package weak var sourceWindow: NSWindow?
    /// Render server: the panel's content, the pill inset by its shadow's room.
    private let panelContainer: NSView?
    /// The pill's glass: it blurs what is behind its window in a clear panel, what is under it in the window's
    /// own top layer.
    private let glass: GlassPanelView
    /// Render server: what the source window's overlay presents, the pill inside it.
    private let carrier = LinkDragGhostView(frame: .zero)
    private var host: Host = .hidden
    /// ``close()`` ran: nothing shows the pill again.
    private var isClosed = false
    private static let offset = CGPoint(x: 14, y: 10)
    private static let maxWidth: CGFloat = 320
    private static let height: CGFloat = 28
    /// The overlay host keeps an overlay this far inside the window (`WindowOverlayHost.origin`): the
    /// carrier sits there, and the pill inside it anywhere, since the carrier does not clip.
    private static let overlayInset: CGFloat = 8
    /// Render server: the pill draws its own shadow (the panel draws none), with this room around it.
    private static var shadowRoom: CGFloat { PopupStyle.standard.shadowMargin }

    /// Where the pill shows: the panel or the source window's overlay host (``carrier``).
    private enum Host {
        case hidden, panel, window(OverlayHandle)
    }

    /// - Parameters:
    ///   - sourceWindow: The window the drag started in (render server: the pill shows in its overlay).
    ///   - rendersOnServer: `motion.renderServer`, read once for the drag.
    package init(title: String, sourceWindow: NSWindow? = nil, rendersOnServer: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        let height = Self.height
        let width = min(Self.maxWidth, ceil(label.intrinsicContentSize.width) + Metrics.space2 * 3)
        let size = CGSize(width: width, height: height)
        let room = rendersOnServer ? Self.shadowRoom : 0
        let panelSize = CGSize(width: size.width + room * 2, height: size.height + room * 2)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        ThemeScope.app.adopt(panel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !rendersOnServer
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let glass = Glass.makePanel(style: .regular, cornerRadius: height / 2)
        glass.translatesAutoresizingMaskIntoConstraints = true
        // The pill is the whole content of a clear panel (or of the window's clear overlay panel).
        glass.samplesBehindWindow = true
        glass.frame = NSRect(origin: .zero, size: size)
        glass.autoresizingMask = [.width, .height]
        label.frame = NSRect(x: Metrics.space2 * 1.5, y: (height - label.intrinsicContentSize.height) / 2,
                             width: width - Metrics.space2 * 3, height: label.intrinsicContentSize.height)
        let pill = LinkDragGhostView(frame: NSRect(origin: .zero, size: size))
        pill.addSubview(glass)
        pill.addSubview(label)
        var container: LinkDragGhostView?
        if rendersOnServer {
            // The pill moves between this panel and the source window's overlay: it keeps the app theme and
            // the popover shadow (PopupStyle.elevation2, on a path, so it costs no offscreen pass) in both.
            pill.appearance = panel.appearance
            pill.wantsLayer = true
            let elevation = PopupStyle.elevation2
            pill.layer?.shadowColor = ThemeScope.app.perform { Palette.shadow.cgColor }
            pill.layer?.shadowOpacity = Float(elevation.alpha)
            pill.layer?.shadowRadius = elevation.layerRadius
            pill.layer?.shadowOffset = elevation.layerOffset()
            let corner = min(width, height) / 2
            pill.layer?.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
            let view = LinkDragGhostView(frame: NSRect(origin: .zero, size: panelSize))
            view.wantsLayer = true
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            container = view
        } else {
            panel.contentView = pill
        }
        self.panel = panel
        self.pill = pill
        self.glass = glass
        panelContainer = container
        self.sourceWindow = sourceWindow
        self.rendersOnServer = rendersOnServer
        carrier.wantsLayer = true
        carrier.clipsToBounds = false
    }

    /// The pill's screen rect for the pointer at `screenPoint` (y up): just right of and below it.
    package func frame(at screenPoint: CGPoint) -> CGRect {
        let size = pill.frame.size
        return CGRect(origin: CGPoint(x: screenPoint.x + Self.offset.x, y: screenPoint.y - Self.offset.y - size.height), size: size)
    }

    /// Shows the pill just right of and below the pointer at `screenPoint` (y up). `holds` answers whether the
    /// source window shows a screen rect in front of every other window (nil: it shows none); on the render
    /// server its overlay holds the pill only then, else the panel does. A closed pill shows nothing.
    package func move(to screenPoint: CGPoint, holds: ((CGRect) -> Bool)? = nil) {
        guard !isClosed else { return }
        let rect = frame(at: screenPoint)
        guard rendersOnServer else {
            panel.setFrameOrigin(rect.origin)
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        place(rect.origin, inSourceWindow: holdsPill(rect, holds: holds))
    }

    package func close() {
        isClosed = true
        leaveHost()
        panel.orderOut(nil)
        panel.close()
    }

    /// Whether the source window's overlay can show the pill at `rect`: the window is on screen and in front
    /// of every other window over all of it.
    private func holdsPill(_ rect: CGRect, holds: ((CGRect) -> Bool)?) -> Bool {
        guard let holds, let window = sourceWindow, window.isVisible, !window.isMiniaturized else { return false }
        return holds(rect)
    }

    // MARK: Hosts

    /// Puts the pill at the screen `origin` in the source window's overlay or, outside it, in the panel.
    private func place(_ origin: CGPoint, inSourceWindow: Bool) {
        if inSourceWindow, let window = sourceWindow {
            if case .window = host { return setOrigin(origin) }
            leaveHost()
            let bounds = NSRect(origin: .zero, size: window.frame.size).insetBy(dx: Self.overlayInset, dy: Self.overlayInset)
            carrier.frame = bounds
            carrier.addSubview(pill)
            host = .window(WindowOverlayHost.host(for: window).present(carrier, options: OverlayOptions(kind: .dragGhost, anchor: bounds)))
            // The overlay is the window's own top layer (the page under the pill is in it) or a clear child panel.
            glass.samplesBehindWindow = carrier.window !== window
            return setOrigin(origin)
        }
        if case .panel = host { return setOrigin(origin) }
        leaveHost()
        let room = Self.shadowRoom
        pill.setFrameOrigin(CGPoint(x: room, y: room))
        panelContainer?.addSubview(pill)
        glass.samplesBehindWindow = true
        host = .panel
        setOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Moves the pill to the screen `origin` in its host: a view origin in the overlay, the panel's origin
    /// outside.
    private func setOrigin(_ origin: CGPoint) {
        switch host {
        case .hidden:
            return
        case .window:
            guard let overlay = carrier.window else { return }
            let local = carrier.convert(overlay.convertPoint(fromScreen: origin), from: nil)
            if pill.frame.origin != local { pill.setFrameOrigin(local) }
        case .panel:
            let room = Self.shadowRoom
            let panelOrigin = CGPoint(x: origin.x - room, y: origin.y - room)
            if panel.frame.origin != panelOrigin { panel.setFrameOrigin(panelOrigin) }
        }
    }

    /// Takes the pill out of its host; the panel leaves the screen.
    private func leaveHost() {
        switch host {
        case .hidden: return
        case .window(let handle): handle.dismiss()
        case .panel: panel.orderOut(nil)
        }
        pill.removeFromSuperview()
        host = .hidden
    }

    /// Where the pill shows (tests, diagnostics): "panel", "window" (the source window's overlay) or "hidden".
    package var hostName: String {
        guard rendersOnServer else { return panel.isVisible ? "panel" : "hidden" }
        switch host {
        case .hidden: return "hidden"
        case .panel: return "panel"
        case .window: return "window"
        }
    }
}

/// Layer-backed view of the pill that never takes the mouse.
private final class LinkDragGhostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
