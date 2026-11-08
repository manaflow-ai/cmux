public import AppKit

/// `window.titlebar` in cmux.json.
public nonisolated enum TitlebarStyle: String, Sendable, CaseIterable, Codable {
    /// No titlebar strip (the default, user nxdog9): content reaches the
    /// window's top edge, the traffic lights sit in the top row, and every
    /// empty area of that row moves the window.
    case minimal
    /// A titlebar strip with the workspace name above the content.
    case standard
}

/// Titlebar behavior for the app's own drag areas (empty tab strip space,
/// the sidebar header, the titlebar strip), matching a native titlebar.
@MainActor
public struct WindowTitlebar {
    public init() {}
    /// What a titlebar double-click does: the user's macOS setting (System
    /// Settings > Desktop & Dock > "Double-click a window's title bar to").
    public enum DoubleClickAction: Equatable, Sendable {
        case zoom
        case minimize
        case none
    }

    /// Reads `AppleActionOnDoubleClick` ("Maximize", "Fill", "Minimize",
    /// "None"; the global domain), falling back to the older
    /// `AppleMiniaturizeOnDoubleClick`. macOS's default is zoom.
    public static func doubleClickAction(defaults: UserDefaults = .standard) -> DoubleClickAction {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        case "Maximize", "Fill": return .zoom
        default:
            return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? .minimize : .zoom
        }
    }

    /// Runs the titlebar double-click action on `window`.
    public static func performDoubleClick(in window: NSWindow?, action: DoubleClickAction = doubleClickAction()) {
        guard let window else { return }
        switch action {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }

    /// The last press `handleMouseDown` ran (window number, timestamp, click count).
    private static var handledPress: (Int, TimeInterval, Int)?

    /// A mouse-down on an empty titlebar area: a double-click runs the
    /// user's action, any other press moves the window with the pointer.
    /// One press runs once: a press on a view that handles its own titlebar
    /// row (Home's header strip) also reaches the window's `sendEvent`, and a
    /// second zoom put the window back where it was (Leo, cosmic-gray 2026-10-13).
    public static func handleMouseDown(_ event: NSEvent, in window: NSWindow?) {
        let press = (event.windowNumber, event.timestamp, event.clickCount)
        if let handledPress, handledPress == press { return }
        handledPress = press
        if event.clickCount == 2 {
            performDoubleClick(in: window)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// The traffic lights' frame in window coordinates, or nil when they
    /// do not show (fullscreen, a window without them).
    ///
    /// While a window leaves full screen AppKit lays it out at its windowed
    /// size before the lights are back in it (they are still in the full
    /// screen titlebar, and the style mask may still say full screen): a
    /// ``TrafficLightsResting`` window answers with the frame they come back
    /// to, so the top row lays out once, for where it rests, and does not
    /// jump when the animation ends (fullscreen-lag).
    public static func trafficLightsFrame(in window: NSWindow) -> CGRect? {
        // Before the style mask: it may still say full screen while the window shrinks back.
        if let resting = (window as? any TrafficLightsResting)?.restingTrafficLights { return resting }
        guard !window.styleMask.contains(.fullScreen) else { return nil }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let frames = buttons.compactMap { type -> CGRect? in
            guard let button = window.standardWindowButton(type), !button.isHidden, button.window === window else { return nil }
            return button.convert(button.bounds, to: nil)
        }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Aligns both edges of a titlebar control to the display's device-pixel grid.
    ///
    /// - Parameters:
    ///   - frame: The control's proposed frame.
    ///   - scale: The window's current backing scale factor.
    /// - Returns: A pixel-aligned frame whose center moves by at most half a device pixel.
    public static func alignedFrame(_ frame: CGRect, scale: CGFloat) -> CGRect {
        let pixelScale = max(1, scale)
        let minX = (frame.minX * pixelScale).rounded() / pixelScale
        let minY = (frame.minY * pixelScale).rounded() / pixelScale
        let maxX = (frame.maxX * pixelScale).rounded() / pixelScale
        let maxY = (frame.maxY * pixelScale).rounded() / pixelScale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Places titlebar accessories after the toolbar band on the traffic lights' center line.
    ///
    /// - Parameters:
    ///   - band: The toolbar band's frame in the accessories' parent coordinates.
    ///   - badge: The badge whose width is reserved, including while temporarily hidden.
    ///   - indicator: The pressure indicator, laid out only while visible.
    ///   - indicatorWidth: The indicator's width supplied by its owner.
    ///   - midY: The traffic lights' center in the accessories' parent coordinates.
    ///   - scale: The window's current backing scale factor.
    ///   - trailing: A quiet mark after them, shown only while `showsTrailing` (hidden otherwise).
    public static func layoutAccessories(after band: CGRect, badge: NSView?, indicator: NSView?,
                                         indicatorWidth: CGFloat, centeredOn midY: CGFloat, scale: CGFloat,
                                         trailing: NSView? = nil, showsTrailing: Bool = true) {
        var x = band.maxX + Metrics.space2
        if let badge {
            let size = badge.fittingSize
            badge.frame = alignedFrame(CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height), scale: scale)
            x = badge.frame.maxX + Metrics.space2
        }
        if let indicator, !indicator.isHidden {
            let side = TitlebarBandButton.side
            indicator.frame = alignedFrame(CGRect(x: x, y: midY - side / 2, width: indicatorWidth, height: side), scale: scale)
            x = indicator.frame.maxX + Metrics.space2
        }
        // Last, a quiet text mark such as Swift live mode's (LiveModeBadgeView).
        trailing?.isHidden = !showsTrailing
        guard let trailing, showsTrailing else { return }
        let size = trailing.fittingSize
        trailing.frame = alignedFrame(CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height), scale: scale)
    }

    /// The main pane card's top inset in `root` (the window's root view):
    /// `gutter`, except under a minimal titlebar, where the card moves down
    /// so the top row's tab pills center on the traffic lights' line with
    /// equal gaps above and below them (never more than `gutter`;
    /// `topRowCardTop`, `PaneChromeMetrics.cardTop`).
    ///
    /// - Parameter clearsTrafficLights: The lights sit over the card and no
    ///   top-row strip makes room for them (tab bars at the bottom, no
    ///   sidebar under the lights): the card starts `gutter` below their row
    ///   (the lights and the toolbar band's buttons on their line).
    public static func cardTopInset(of root: NSView, minimal: Bool, gutter: CGFloat, clearsTrafficLights: Bool = false) -> CGFloat {
        guard minimal, let window = root.window else { return gutter }
        // Under a minimal titlebar the card meets the window's top edge: it stays under the window's lit rim.
        guard let lights = trafficLightsFrame(in: window) else { return Metrics.windowEdgeInset(gutter, in: window) }
        let local = root.convert(lights, from: nil)
        if clearsTrafficLights {
            let row = max(local.height, TitlebarBandButton.side)
            return max(gutter, root.bounds.maxY - local.midY + row / 2 + gutter).rounded(.up)
        }
        // Floating panes keep the one even gap at the top too.
        guard !Metrics.floatingPanes else { return gutter }
        // The top row's shared line (`TopRowLine`): the lights' center unless Debug picks another variant.
        // Concentric (the default line): the gutter on top as at the sides, with or without a top-row strip.
        guard let target = targetTopRowLine(in: window) else {
            // No top-row strip (tab bars at the bottom): the card keeps its place from before #38054.
            let card = PaneChromeMetrics.current.cardTopKeepingStripCentering(centeringPillOn: root.bounds.maxY - local.midY,
                                                                              scale: window.backingScaleFactor)
            return Metrics.windowEdgeInset(min(gutter, card), in: window)
        }
        return topRowCardTop(centeringPillOn: target.centerY, gutter: gutter, in: window)
    }

    /// Whether `view` sits in the window's titlebar band (a full-size
    /// content view in the top row, even when the layout pads it a few
    /// points below the window's top edge).
    public static func isInTopRow(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return isInTopRow(view.convert(view.bounds, to: nil), in: window)
    }

    /// Whether `frame` (window coordinates) lies in `window`'s titlebar band: a view's frame where
    /// its pane will rest, for chrome that lays out once for its final place.
    public static func isInTopRow(_ frame: CGRect, in window: NSWindow) -> Bool {
        let band = TitlebarDragPolicy.bandRect(in: window)
        return band.height > 0 && frame.maxY > band.minY && frame.minY < band.maxY
    }
}

/// A window with a view in its top row after the traffic lights (an
/// incognito window's badge while the sidebar is hidden). Tab strips under
/// it start their tabs after it.
@MainActor
public protocol TitlebarAccessoryHosting: AnyObject {
    /// The accessory's frame in window coordinates, nil when none shows.
    var titlebarAccessoryFrame: CGRect? { get }
}

/// A window that knows where its traffic lights rest while AppKit has them
/// elsewhere (the end of a full screen exit). ``WindowTitlebar/trafficLightsFrame(in:)``
/// uses it when the window shows none of its own.
@MainActor
public protocol TrafficLightsResting: AnyObject {
    /// The lights' windowed frame in window coordinates while they are away
    /// for a transition, nil at any other time.
    var restingTrafficLights: CGRect? { get }
}
