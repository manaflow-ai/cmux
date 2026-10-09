import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings

/// OSC 7501 notifications (cx-kxa2): the daemon posts them; here the app
/// finds the record behind one, drops a `done` the user can already see, and
/// gives the banner a status badge image.
extension NotificationCenterService {
    /// The OSC 7501 record a `terminal` notification was posted for.
    func programStatus(of notification: DaemonNotification, source: NotificationSource,
                       located: LocatedTab) -> ProgramStatusNotification? {
        guard source == .terminal else { return nil }
        return ProgramStatusNotification.match(title: notification.title, body: notification.body,
                                               level: notification.level, records: located.tab.programStatus)
    }

    /// Where the tab is for the user now (status-indicators.md visibility
    /// rule): the selected tab of its pane, in the workspace a visible window
    /// shows, while cmux is active. A pane of the shown workspace counts as on
    /// screen.
    func visibility(of located: LocatedTab) -> TerminalVisibility {
        guard let services else { return .hidden }
        let pane = located.pane
        let fallback = pane.tabs.indices.contains(pane.defaultTabIndex) ? pane.tabs[pane.defaultTabIndex].id : nil
        // One window must both select the tab and be visible; flags from
        // different windows never combine.
        let shown = services.windows.controllers.contains { controller in
            controller.state.workspaceID == located.workspace.id && controller.state.page == nil
                && (controller.state.selection.selection(in: pane.id) ?? fallback) == located.tab.id
                && (controller.window?.occlusionState.contains(.visible) ?? false)
        }
        var visibility = TerminalVisibility.hidden
        visibility.appActive = NSApp.isActive
        if shown {
            visibility.tabSelected = true
            visibility.paneOnScreen = true
            visibility.windowShown = true
        }
        return visibility
    }
}

/// The badge image a status notification attaches: the status glyph the
/// sidebar draws for the reason, on the theme's surface, as a PNG file
/// `UNNotificationAttachment` can take (the center moves the file, so each
/// banner gets its own copy).
@MainActor
enum StatusNotificationImage {
    static let side: CGFloat = 64

    /// PNG data per reason (six images; drawn once per theme).
    private static var cache: [String: Data] = [:]

    /// The badge PNG for `reason`, cached per reason and theme.
    static func data(_ reason: ProgramStatusNotification.Reason) -> Data? {
        let key = "\(reason.rawValue)-\(ThemeScope.app.tokens.surfaceBackground)"
        if let cached = cache[key] { return cached }
        let drawn = png(reason)
        cache[key] = drawn
        return drawn
    }

    static func png(_ reason: ProgramStatusNotification.Reason) -> Data? {
        let tokens = ThemeScope.app.tokens
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let tile = CGRect(x: 0, y: 0, width: side, height: side)
        context.addPath(CGPath(roundedRect: tile, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil))
        context.setFillColor(tokens.surfaceBackground.withAlpha(1).nsColor.cgColor)
        context.fillPath()
        let indicator = StatusIndicatorLayer()
        indicator.contentsScale = scale
        indicator.colors = StatusIndicatorLayer.Colors(
            loading: tokens.textSecondary.nsColor.cgColor, attention: tokens.attention.nsColor.cgColor,
            danger: tokens.danger.nsColor.cgColor, success: tokens.success.nsColor.cgColor,
            accent: tokens.textPrimary.nsColor.cgColor)
        let glyph = side * 0.5
        indicator.frame = CGRect(x: (side - glyph) / 2, y: (side - glyph) / 2, width: glyph, height: glyph)
        indicator.apply(.make(reason.indicator, style: .arc, animates: false), config: StatusIndicatorConfig(animatesLoops: false))
        context.translateBy(x: indicator.frame.minX, y: indicator.frame.minY)
        indicator.layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
