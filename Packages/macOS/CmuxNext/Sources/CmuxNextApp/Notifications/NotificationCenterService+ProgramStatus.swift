import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// OSC 7501 notifications (cx-kxa2): the daemon posts them; here the app
/// finds the record behind one, drops a `done` the user can already see, and
/// gives the banner a reason line and a status badge image.
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
        var visibility = TerminalVisibility.hidden
        visibility.appActive = NSApp.isActive
        for controller in services.windows.controllers where controller.state.workspaceID == located.workspace.id
            && controller.state.page == nil {
            let selected = (controller.state.selection.selection(in: pane.id) ?? fallback) == located.tab.id
            let shown = controller.window?.occlusionState.contains(.visible) ?? false
            if selected && shown {
                return TerminalVisibility(tabSelected: true, paneOnScreen: true, windowShown: true, appActive: visibility.appActive)
            }
            visibility.tabSelected = visibility.tabSelected || selected
            visibility.windowShown = visibility.windowShown || shown
            visibility.paneOnScreen = true
        }
        return visibility
    }

    /// The banner's reason line ("Needs permission", "Done").
    static func reasonLine(_ reason: ProgramStatusNotification.Reason) -> String {
        switch reason {
        case .permission:
            String(localized: "programStatusNotification.permission", defaultValue: "Needs permission",
                   table: "ProgramStatusNotifications", bundle: .module)
        case .question:
            String(localized: "programStatusNotification.question", defaultValue: "Has a question",
                   table: "ProgramStatusNotifications", bundle: .module)
        case .auth:
            String(localized: "programStatusNotification.auth", defaultValue: "Needs sign-in",
                   table: "ProgramStatusNotifications", bundle: .module)
        case .input:
            String(localized: "programStatusNotification.input", defaultValue: "Needs input",
                   table: "ProgramStatusNotifications", bundle: .module)
        case .failed:
            String(localized: "programStatusNotification.failed", defaultValue: "Failed",
                   table: "ProgramStatusNotifications", bundle: .module)
        case .done:
            String(localized: "programStatusNotification.done", defaultValue: "Done",
                   table: "ProgramStatusNotifications", bundle: .module)
        }
    }
}

/// The badge image a status notification attaches: the status glyph the
/// sidebar draws for the reason, on the theme's surface, as a PNG file
/// `UNNotificationAttachment` can take (the center moves the file, so each
/// banner gets its own copy).
@MainActor
enum StatusNotificationImage {
    static let side: CGFloat = 64

    /// A fresh PNG for `reason`, nil when it cannot be drawn or written.
    static func write(_ reason: ProgramStatusNotification.Reason) -> URL? {
        guard let data = png(reason) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-status-notifications", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(reason.rawValue)-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
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
