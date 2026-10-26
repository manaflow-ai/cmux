import AppKit
import CmuxNextDesign
import CmuxNextDevices
import CmuxScreenKit
import Observation

/// A Mac Screen tab's toolbar (AppKit): the status dot, the Mac's name, the
/// stream's stats, View Only, the keyboard release hint and, while a session
/// streams, the display, quality and Send Keys menus, Refresh and
/// Connect / Disconnect. The views are made once; Observation updates them.
///
/// In a narrow pane the controls keep their size. The stats and the release
/// hint show whole or not at all, then the icon goes, so the name keeps the
/// room that is left (the layout `ViewThatFits` and layout priorities gave).
@MainActor
final class MacScreenToolbarView: MacScreenThemedView {
    private let model: MacScreenPaneModel
    private let actions: MacScreenChromeActions
    private let dot = MacScreenFill(\.tertiary, shape: .circle)
    private let icon = MacScreenGlyph("desktopcomputer", font: MacScreenType.body)
    private let name = MacScreenText("", font: MacScreenType.emphasized)
    private let stats = MacScreenText("", font: MacScreenType.stats, ink: \.secondary)
    private let badge: MacScreenFill
    private let badgeGlyph = MacScreenGlyph("eye", font: MacScreenType.badge, ink: \.attention)
    private let badgeText = MacScreenText(L.t("macScreen.toolbar.viewOnly", "View Only"), font: MacScreenType.badge, ink: \.attention)
    private let hint: NSStackView
    private let hintGlyph = MacScreenGlyph("keyboard", font: MacScreenType.caption)
    private let hintText = MacScreenText(L.t("macScreen.toolbar.releaseHint", "⌃⌥⎋ releases the keyboard"), font: MacScreenType.caption, ink: \.secondary)
    private let displayButton: MacScreenMenuButton
    private let quality: MacScreenMenuButton
    private let sendKeys: MacScreenMenuButton
    private let refresh: MacScreenButton
    private let connect: MacScreenButton
    private let disconnect: MacScreenButton
    private let line = MacScreenFill(\.separator)
    /// Slots shown now (the stats and hint slots exist while their condition holds, whether or not they fit).
    private var statsSlot = false
    private var hintSlot = false
    private var controlsShown = false

    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 12

    init(model: MacScreenPaneModel, actions: MacScreenChromeActions) {
        self.model = model
        self.actions = actions
        badge = MacScreenFill(\.attentionWash, shape: .rounded(0))
        let badgeContent = MacScreenStack.make(.horizontal, spacing: 4, alignment: .centerY, [badgeGlyph, badgeText], insets: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
        badge.addSubview(badgeContent)
        NSLayoutConstraint.activate([
            badgeContent.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            badgeContent.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            badgeContent.topAnchor.constraint(equalTo: badge.topAnchor),
            badgeContent.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
        ])
        badge.setAccessibilityElement(true)
        badge.setAccessibilityRole(.staticText)
        badge.setAccessibilityLabel(L.t("macScreen.toolbar.viewOnly", "View Only"))
        badge.setAccessibilityIdentifier("macScreen.viewOnly")
        hint = MacScreenStack.make(.horizontal, spacing: 4, alignment: .centerY, [hintGlyph, hintText])
        hint.themedToolTip = L.t("macScreen.toolbar.keyboardHint", "Keyboard goes to this Mac · ⌃⌥⎋ to release")
        displayButton = MacScreenMenuButton(symbol: "display.2", title: "", accessibilityTitle: "", id: "macScreen.display")
        quality = MacScreenMenuButton(symbol: "slider.horizontal.3", accessibilityTitle: L.t("macScreen.toolbar.quality", "Quality"),
                                      id: "macScreen.quality")
        quality.themedToolTip = L.t("macScreen.toolbar.qualityHelp", "Quality and stats")
        sendKeys = MacScreenMenuButton(symbol: "command", accessibilityTitle: L.t("macScreen.toolbar.sendKeys", "Send Keys"), id: "macScreen.sendKeys")
        refresh = MacScreenButton(L.t("macScreen.toolbar.refresh", "Refresh Screen"), role: .icon, symbol: "arrow.clockwise") { actions.refresh() }
        refresh.themedToolTip = L.t("macScreen.toolbar.refresh", "Refresh Screen")
        connect = MacScreenButton(L.t("macScreen.toolbar.connect", "Connect"), role: .primary, compact: true, id: "macScreen.connect") {
            actions.connect()
        }
        disconnect = MacScreenButton(L.t("macScreen.toolbar.disconnect", "Disconnect"), compact: true, id: "macScreen.disconnect") {
            actions.disconnect()
        }
        super.init(frame: .zero)
        wantsLayer = true
        stats.setAccessibilityIdentifier("macScreen.stats")
        for view in [dot, icon, name, stats, badge, hint, displayButton, quality, sendKeys, refresh, connect, disconnect, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        displayButton.makeMenu = { [weak self] in self?.displayMenu() ?? NSMenu() }
        quality.makeMenu = { [weak self] in self?.qualityMenu() ?? NSMenu() }
        sendKeys.makeMenu = { [weak self] in self?.sendKeysMenu() ?? NSMenu() }
        track()
    }

    override var isFlipped: Bool { true }

    override func colorsChanged() {
        layer?.backgroundColor = colors.chrome.cgColor
        line.isHidden = !colors.borders
        super.colorsChanged()
    }

    // MARK: State

    /// Shows the model's state; again on every change of a value read here.
    private func track() {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        needsLayout = true
    }

    private func apply() {
        applyType()
        dot.fill = statusColor
        if name.stringValue != model.name { name.stringValue = model.name }
        let session = model.session
        let live = model.isLive
        statsSlot = session != nil && live && session?.preferences.showStats == true
        if statsSlot, let session { stats.stringValue = Self.statsLine(session) }
        let viewOnly = model.viewOnly
        setThemedTip(viewOnly
            ? String(format: L.t("macScreen.toolbar.viewOnlyHelpNamed", "You can see %@ but not control it. Your clicks, keys and scrolling aren’t sent."), model.name)
            : nil, on: badge)
        badge.isHidden = !viewOnly
        hintSlot = model.capturesKeyboard && live
        controlsShown = session != nil && model.showsStreamControls
        let displayCount = model.displays.count
        displayButton.retitle(String(format: L.t("macScreen.toolbar.displayShort", "Display %d"), model.currentDisplay + 1))
        displayButton.isHidden = !controlsShown || displayCount <= 1
        quality.isHidden = !controlsShown
        let canSend = live && !viewOnly
        sendKeys.isHidden = !controlsShown
        sendKeys.isEnabled = canSend
        sendKeys.ink = canSend ? \.secondary : \.tertiary
        setThemedTip(viewOnly
            ? L.t("macScreen.toolbar.sendKeysViewOnly", "Send Keys is off in a View Only session")
            : L.t("macScreen.toolbar.sendKeys", "Send Keys"), on: sendKeys)
        refresh.isHidden = !controlsShown
        refresh.isEnabled = live
        let ended: Bool = switch session?.phase {
        case .ended?, .failed?: true
        default: false
        }
        connect.isHidden = !controlsShown || !ended
        disconnect.isHidden = !controlsShown || ended
    }

    /// The labels, glyphs and buttons at the type scale's sizes, read here so a density, font size
    /// or interface scale change shows at once (the views are made once).
    private func applyType() {
        let fonts: [(MacScreenText, NSFont)] = [(name, MacScreenType.emphasized), (stats, MacScreenType.stats),
                                                (badgeText, MacScreenType.badge), (hintText, MacScreenType.caption)]
        var changed = false
        for (label, font) in fonts where label.font != font {
            label.font = font
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        icon.resize(to: MacScreenType.body)
        badgeGlyph.resize(to: MacScreenType.badge)
        hintGlyph.resize(to: MacScreenType.caption)
        guard changed else { return }
        for button in [displayButton, quality, sendKeys] { button.reloadType() }
        for button in [refresh, connect, disconnect] { button.reloadType() }
    }

    /// Sets a tooltip only when it changes (the stats redraw this every second).
    private func setThemedTip(_ text: String?, on view: NSView) {
        if view.themedToolTip != text { view.themedToolTip = text }
    }

    private var statusColor: KeyPath<MacScreenColors, NSColor> {
        if let hub = model.hub {
            switch hub.phase {
            case .requesting, .waitingForApproval, .approved: return \.attention
            case .declined, .refused, .revoked: return \.danger
            case .idle, .ended: return \.tertiary
            case .streaming, .streamFailed: break
            }
        }
        guard model.gate == .open, let session = model.session else { return \.tertiary }
        switch session.phase {
        case .connected: return session.isReconnecting ? \.attention : \.success
        case .connecting: return \.attention
        case .failed: return \.danger
        case .ended: return \.tertiary
        }
    }

    static func statsLine(_ session: ScreenSession) -> String {
        let stats = session.stats
        return statsLine(path: session.streamPath, fps: stats.fps, targetFps: stats.targetFps, latencyMs: stats.latencyMs,
                         encoding: stats.encoding, frameSize: session.frameSize)
    }

    /// The stats line: path, frame rate (measured, then the rate the Mac
    /// streams at when it says: "118/120 fps"), round trip, codec, size.
    static func statsLine(path: String, fps: Double, targetFps: Int?, latencyMs: Double?, encoding: String, frameSize: CGSize) -> String {
        let measured = fps.isFinite ? Int(fps.rounded()) : 0
        let rate = targetFps.map { target in
            L.t("macScreen.stats.fpsOfTarget", "\(measured)/\(target) fps")
        } ?? String(format: "%.0f fps", fps)
        var parts = [path, rate]
        if let rtt = latencyMs { parts.append(String(format: "%.0f ms", rtt)) }
        if encoding != "-" { parts.append(encoding) }
        if frameSize.width >= 1 { parts.append("\(Int(frameSize.width))×\(Int(frameSize.height))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Menus

    private func displayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, size) in model.displays.enumerated() {
            let title = String(format: L.t("macScreen.toolbar.display", "Display %d (%d × %d)"), index + 1, Int(size.width), Int(size.height))
            menu.addItem(NSMenuItem.macScreen(title, checked: model.currentDisplay == index) { [weak self] in self?.actions.selectDisplay(index) })
        }
        return menu
    }

    private func qualityMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let session = model.session else { return menu }
        for quality in ScreenQuality.allCases {
            menu.addItem(NSMenuItem.macScreen(Self.qualityTitle(quality), checked: session.preferences.quality == quality) { [weak self] in
                self?.actions.setQuality(quality)
            })
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.toolbar.showStats", "Show Stats"), checked: session.preferences.showStats) { [weak self] in
            self?.actions.toggleStats()
        })
        return menu
    }

    private func sendKeysMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let shortcuts = model.systemShortcuts {
            // The setting (macScreen.systemShortcuts): every Mac Screen tab follows it.
            let enabled = shortcuts.enabled
            menu.addItem(NSMenuItem.macScreen(L.t("macScreen.keys.systemShortcuts", "Send System Shortcuts to the Remote Mac"), checked: enabled) {
                shortcuts.setEnabled(!enabled)
            })
            if shortcuts.needsAccessibility {
                menu.addItem(NSMenuItem.macScreen(L.t("macScreen.keys.allowAccessibility", "Allow Accessibility for System Shortcuts…")) {
                    shortcuts.requestAccessibility()
                })
            }
            menu.addItem(.separator())
        }
        for shortcut in MacScreenShortcut.all {
            menu.addItem(NSMenuItem.macScreen(shortcut.title) { [weak self] in self?.actions.sendKeys(shortcut) })
        }
        return menu
    }

    static func qualityTitle(_ quality: ScreenQuality) -> String {
        switch quality {
        case .auto: L.t("macScreen.quality.auto", "Auto")
        case .smooth: L.t("macScreen.quality.smooth", "Smooth Motion")
        case .low: L.t("macScreen.quality.low", "Fixed Low (720p)")
        case .medium: L.t("macScreen.quality.medium", "Fixed Medium (1080p)")
        case .high: L.t("macScreen.quality.high", "Fixed High (Full)")
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let height = bounds.height
        line.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)
        let gap = Self.spacing
        let controls: [NSView] = [displayButton, quality, sendKeys, refresh, connect, disconnect].filter { !$0.isHidden }
        let controlSizes = controls.map(\.fittingSize)
        let controlsWidth = controlSizes.isEmpty ? 0 : controlSizes.reduce(0) { $0 + $1.width } + gap * CGFloat(controlSizes.count - 1)
        let badgeSize = badge.isHidden ? .zero : badge.fittingSize
        let hintSize = hint.fittingSize
        let statsWidth = Self.textWidth(stats)
        let iconWidth = ceil(icon.intrinsicContentSize.width)
        let nameWidth = Self.textWidth(name)
        // The row: dot, name group, [stats], spacer, [badge], [hint], [controls].
        let slots = 3 + (statsSlot ? 1 : 0) + (badge.isHidden ? 0 : 1) + (hintSlot ? 1 : 0) + (controls.isEmpty ? 0 : 1)
        let available = bounds.width - Self.padding * 2
        let reserved = 7 + 8 + badgeSize.width + controlsWidth + gap * CGFloat(slots - 1)
        let offered = available - reserved
        let showsIcon = offered >= iconWidth + gap + nameWidth
        let nameUsed = showsIcon ? nameWidth : max(24, min(nameWidth, offered))
        var left = offered - (showsIcon ? iconWidth + gap + nameWidth : nameUsed)
        let showsStats = statsSlot && left >= statsWidth
        if showsStats { left -= statsWidth }
        let showsHint = hintSlot && left >= hintSize.width
        if showsHint { left -= hintSize.width }

        var x = Self.padding
        func place(_ view: NSView, width: CGFloat, height viewHeight: CGFloat) {
            view.frame = CGRect(x: x, y: ((height - viewHeight) / 2).rounded(), width: width, height: viewHeight)
            x += width + gap
        }
        place(dot, width: 7, height: 7)
        icon.isHidden = !showsIcon
        if showsIcon { place(icon, width: iconWidth, height: icon.intrinsicContentSize.height) }
        place(name, width: nameUsed, height: name.intrinsicContentSize.height)
        // A slot that does not fit keeps its spacing (as SwiftUI's empty fallback did) and stays hidden.
        stats.isHidden = !showsStats
        if showsStats { place(stats, width: statsWidth, height: stats.intrinsicContentSize.height) } else if statsSlot { x += gap }
        x += 8 + max(0, left) + gap
        if !badge.isHidden {
            place(badge, width: badgeSize.width, height: badgeSize.height)
            badge.layer?.cornerRadius = badgeSize.height / 2
        }
        hint.isHidden = !showsHint
        if showsHint { place(hint, width: hintSize.width, height: hintSize.height) } else if hintSlot { x += gap }
        for (view, size) in zip(controls, controlSizes) { place(view, width: size.width, height: size.height) }
    }
}

extension MacScreenToolbarView {
    /// A one-line label's whole width (its cell's, so the text never truncates when it fits).
    static func textWidth(_ label: NSTextField) -> CGFloat {
        let cell = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1000)).width
        return ceil(max(cell ?? 0, label.attributedStringValue.size().width + 4))
    }
}

extension MacScreenColors {
    /// The View Only badge's capsule: the attention color, faint.
    var attentionWash: NSColor { attention.withAlphaComponent(attention.alphaComponent * 0.14) }
}
