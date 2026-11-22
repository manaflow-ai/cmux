import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

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

    /// How long an alert waits for its record before it shows without one.
    static let programAlertWait: Duration = .milliseconds(1500)

    /// Holds an alert-shaped `terminal` notification until the tab's OSC 7501
    /// records contain its record (observed, no poll), then calls `deliver`
    /// once with the match; after `programAlertWait` it delivers without one.
    func holdUntilRecord(_ notification: DaemonNotification, located: LocatedTab,
                         deliver: @escaping @MainActor @Sendable (ProgramStatusNotification?) -> Void) {
        let id = notification.notification.rawValue
        let tab = located.tab
        let hold = HeldProgramAlert(timer: DemandTimer(owner: "notifications.programAlert", clock: clock))
        let finish: @MainActor @Sendable (ProgramStatusNotification?) -> Void = { [weak self] found in
            guard !hold.delivered else { return }
            hold.delivered = true
            hold.timer.cancel()
            self?.heldProgramAlerts.removeValue(forKey: id)?.cancel()
            deliver(found)
        }
        hold.timer.schedule(after: Self.programAlertWait) { @MainActor in finish(nil) }
        heldProgramAlerts[id] = Task { @MainActor in // task-owner: heldProgramAlerts, cancelled by finish
            for await records in Observations({ tab.programStatus }) {
                if let found = ProgramStatusNotification.match(title: notification.title, body: notification.body,
                                                                level: notification.level, records: records) {
                    finish(found)
                    return
                }
            }
        }
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

/// One held OSC 7501 alert: delivered once, by its record or its deadline.
@MainActor
final class HeldProgramAlert {
    let timer: DemandTimer
    var delivered = false
    init(timer: DemandTimer) { self.timer = timer }
}

/// The badge image a status notification attaches: the status glyph the
/// sidebar draws for the reason, on the theme's surface, as a PNG file
/// `UNNotificationAttachment` can take (the center moves the file, so each
/// banner gets its own copy).
@MainActor
enum StatusNotificationImage {
    static let side: CGFloat = 64

    /// PNG data per reason, icon set and theme.
    private static var cache: [String: Data] = [:]

    /// The badge PNG for `reason` in the chosen status icon set
    /// (`StatusIconSet`), cached per reason, set and theme.
    static func data(_ reason: ProgramStatusNotification.Reason) -> Data? {
        let set = StatusIndicatorAppearance.shared.config.iconSet
        let key = "\(reason.rawValue)-\(set.rawValue)-\(ThemeScope.app.tokens.surfaceBackground)"
        if let cached = cache[key] { return cached }
        let drawn = png(reason, set: set)
        cache[key] = drawn
        return drawn
    }

    /// The badge for `reason` drawn with `set`'s mark (the reason's blocked
    /// kind included) by `StatusIconSet.image`, the drawing the sidebar uses.
    static func png(_ reason: ProgramStatusNotification.Reason, set: StatusIconSet) -> Data? {
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
        let glyph = side * 0.5
        let kind = reason.kind.flatMap { StatusBlockedKind(rawValue: $0.rawValue) }
        let mark = ThemeScope.app.perform {
            set.image(state: reason.indicator, kind: kind, pointSize: glyph, scale: scale, appearance: ThemeScope.app.appearance)
        }
        if let mark = mark?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(mark, in: CGRect(x: (side - glyph) / 2, y: (side - glyph) / 2, width: glyph, height: glyph))
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
