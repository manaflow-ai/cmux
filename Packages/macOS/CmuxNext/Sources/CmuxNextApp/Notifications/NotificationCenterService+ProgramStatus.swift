import AppKit
import CmuxNextBridge
import CmuxNextCompat
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
    /// once with the match; after `programAlertWait` it delivers without one. Both run in the
    /// visible class: the banner is what a program (not the person) asked for.
    func holdUntilRecord(_ notification: DaemonNotification, located: LocatedTab,
                         deliver: @escaping @MainActor (ProgramStatusNotification?) -> Void) {
        let id = notification.notification.rawValue
        let tab = located.tab
        let hold = HeldProgramAlert(deadline: MainDeadline(owner: "notifications.programAlert", workClass: .visible, scheduler: deadlines))
        let finish: @MainActor (ProgramStatusNotification?) -> Void = { [weak self, weak hold] found in
            guard let hold, !hold.delivered else { return }
            hold.delivered = true
            hold.end()
            self?.heldProgramAlerts[id] = nil
            deliver(found)
        }
        hold.deadline.schedule(after: Self.programAlertWait) { finish(nil) }
        hold.records = ServiceObservation(.visible, owner: "notifications.programAlert.records", on: work) {
            ProgramStatusNotification.match(title: notification.title, body: notification.body, level: notification.level,
                                            records: tab.programStatus)
        } apply: { found in
            if let found { finish(found) }
        }
        if !hold.delivered { heldProgramAlerts[id] = hold }
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
    let deadline: MainDeadline
    /// Follows the tab's records until one matches.
    var records: ServiceObservation<ProgramStatusNotification?>?
    var delivered = false
    init(deadline: MainDeadline) { self.deadline = deadline }

    /// Stops the deadline and the observation (the alert was delivered).
    func end() {
        deadline.cancel()
        records?.cancel()
        records = nil
    }
}

/// The badge image a status notification attaches: the status glyph the
/// sidebar draws for the reason, on the theme's surface, as a PNG file
/// `UNNotificationAttachment` can take (the center moves the file, so each
/// banner gets its own copy).
@MainActor
enum StatusNotificationImage {
    static let side: CGFloat = 64

    // memory: fixed at most one badge PNG (128 px, a few KB) per `ProgramStatusNotification.Reason` case, all of one icon set and theme (`look`); a new set or theme empties it first
    /// The icon set and theme the cached badges were drawn with, and their PNG data per reason.
    private static var cache: (look: String, badges: [ProgramStatusNotification.Reason: Data]) = ("", [:])

    /// How many badges are cached now.
    static var cachedCount: Int { cache.badges.count }

    /// The badge PNG for `reason` in the chosen status icon set
    /// (`StatusIconSet`) and the app's theme.
    static func data(_ reason: ProgramStatusNotification.Reason) -> Data? {
        let set = StatusIndicatorAppearance.shared.config.iconSet
        return data(reason, look: "\(set.rawValue)-\(ThemeScope.app.tokens.surfaceBackground)") { png(reason, set: set) }
    }

    /// The cached badge for `reason` in `look` (an icon set and theme), else `draw`'s, kept. A look
    /// other than the cached badges' empties the cache first, so it keeps one badge per reason.
    static func data(_ reason: ProgramStatusNotification.Reason, look: String, draw: () -> Data?) -> Data? {
        if look != cache.look { cache = (look, [:]) }
        if let cached = cache.badges[reason] { return cached }
        let drawn = draw()
        cache.badges[reason] = drawn
        return drawn
    }

    /// The badge for `reason` drawn with `set`'s mark (the reason's blocked
    /// kind included) by `StatusIconSet.image`, the drawing the sidebar uses.
    static func png(_ reason: ProgramStatusNotification.Reason, set: StatusIconSet) -> Data? {
        let tokens = ThemeScope.app.tokens
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext.bitmapOwningPixels(width: pixels, height: pixels, space: space,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let tile = CGRect(x: 0, y: 0, width: side, height: side)
        let rounded = CGMutablePath()
        rounded.addRoundedRect(in: tile, cornerWidth: side * 0.22, cornerHeight: side * 0.22)
        context.addPath(rounded)
        context.setFillColor(tokens.surfaceBackground.withAlpha(1).nsColor.cgColor)
        context.fillPath()
        let glyph = side * 0.5
        let kind = reason.kind.flatMap { StatusBlockedKind(rawValue: $0.rawValue) }
        let mark = ThemeScope.app.perform {
            set.image(state: reason.indicator, kind: kind, pointSize: glyph, scale: scale, appearance: ThemeScope.app.appearance)
        }
        if let mark = mark?.bestCGImage {
            context.draw(mark, in: CGRect(x: (side - glyph) / 2, y: (side - glyph) / 2, width: glyph, height: glyph))
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
