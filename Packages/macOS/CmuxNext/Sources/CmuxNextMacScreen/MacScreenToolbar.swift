import AppKit
import CmuxNextDesign
import CmuxNextDevices
import CmuxScreenKit
import Observation

/// The Mac's name, measured latency and session controls. Wide panes use one
/// row, medium panes separate status and controls, and narrow panes put
/// secondary commands in More. Observation updates the existing views.
@MainActor
final class MacScreenToolbarView: MacScreenThemedView {
    private let model: MacScreenPaneModel
    private let actions: MacScreenChromeActions
    private let dot = MacScreenFill(\.tertiary, shape: .circle)
    private let icon = MacScreenGlyph("desktopcomputer", font: MacScreenType.body)
    private let name = MacScreenText("", font: MacScreenType.emphasized)
    private let stats = MacScreenText("", font: MacScreenType.stats, ink: \.secondary)
    private let access: MacScreenMenuButton
    private let fullScreen: MacScreenButton
    private let more: MacScreenMenuButton
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

    init(model: MacScreenPaneModel, actions: MacScreenChromeActions) {
        self.model = model
        self.actions = actions
        access = MacScreenMenuButton(symbol: "eye", title: "", accessibilityTitle: "", id: "macScreen.access")
        fullScreen = MacScreenButton(L.t("macScreen.toolbar.fullScreen", "Full Screen"), role: .icon,
                                     symbol: "arrow.up.left.and.arrow.down.right", id: "macScreen.fullScreen") { actions.fullScreen() }
        fullScreen.themedToolTip = L.t("macScreen.toolbar.fullScreen", "Full Screen")
        more = MacScreenMenuButton(symbol: "ellipsis", accessibilityTitle: L.t("macScreen.toolbar.more", "More Controls"), id: "macScreen.more")
        hint = MacScreenStack.make(.horizontal, spacing: 4, alignment: .centerY, [hintGlyph, hintText])
        hint.themedToolTip = L.t("macScreen.toolbar.keyboardHint", "Keyboard goes to this Mac · ⌃⌥⎋ to release")
        displayButton = MacScreenMenuButton(symbol: "display.2", title: "", accessibilityTitle: "", id: "macScreen.display")
        quality = MacScreenMenuButton(symbol: "slider.horizontal.3", title: "", accessibilityTitle: L.t("macScreen.toolbar.quality", "Quality"),
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
        for view in [dot, icon, name, stats, access, hint, displayButton, quality, sendKeys, refresh, fullScreen, more, connect, disconnect, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        displayButton.makeMenu = { [weak self] in self?.displayMenu() ?? NSMenu() }
        quality.makeMenu = { [weak self] in self?.qualityMenu() ?? NSMenu() }
        sendKeys.makeMenu = { [weak self] in self?.sendKeysMenu() ?? NSMenu() }
        access.makeMenu = { [weak self] in self?.accessMenu() ?? NSMenu() }
        more.makeMenu = { [weak self] in self?.moreMenu() ?? NSMenu() }
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
        superview?.needsLayout = true
    }

    private func apply() {
        applyType()
        dot.fill = statusColor
        if name.stringValue != model.name { name.stringValue = model.name }
        let session = model.session
        let live = model.isLive
        statsSlot = session != nil && live
        if statsSlot, let session {
            stats.stringValue = session.preferences.showStats ? Self.statsLine(session) : session.stats.latencyMs.map { String(format: "%.0f ms", $0) } ?? "— ms"
        }
        let viewOnly = model.viewOnly
        access.retitle(viewOnly ? L.t("macScreen.scope.view", "View Only") : L.t("macScreen.scope.full", "Full Control"))
        access.image = NSImage(systemSymbolName: viewOnly ? "eye" : "cursorarrow", accessibilityDescription: nil)
        access.ink = viewOnly ? \.attention : \.secondary
        hintSlot = model.capturesKeyboard && live
        controlsShown = session != nil && model.showsStreamControls
        access.isHidden = !controlsShown
        access.isEnabled = controlsShown
        fullScreen.isHidden = !controlsShown
        more.isHidden = !controlsShown
        if let session { quality.retitle(Self.qualityTitle(session.preferences.quality)) }
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
                                                (hintText, MacScreenType.caption)]
        var changed = false
        for (label, font) in fonts where label.font != font {
            label.font = font
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        icon.resize(to: MacScreenType.body)
        hintGlyph.resize(to: MacScreenType.caption)
        guard changed else { return }
        for button in [access, displayButton, quality, sendKeys, more] { button.reloadType() }
        for button in [refresh, fullScreen, connect, disconnect] { button.reloadType() }
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

    static func statsLine(_ session: MacScreenSession) -> String {
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

    private func accessMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (scope, title) in [(SessionScope.view, L.t("macScreen.scope.view", "View Only")), (.full, L.t("macScreen.scope.full", "Full Control"))] {
            let selected = model.hub?.phase.streamingScope == scope
            menu.addItem(NSMenuItem.macScreen(title, checked: selected) { [weak self] in
                guard !selected else { return }
                self?.actions.requestScope(scope)
            })
        }
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.displays.count > 1 {
            let displays = NSMenuItem(title: displayButton.accessibilityLabel() ?? "", action: nil, keyEquivalent: "")
            displays.submenu = displayMenu()
            menu.addItem(displays)
        }
        let keys = NSMenuItem(title: L.t("macScreen.toolbar.sendKeys", "Send Keys"), action: nil, keyEquivalent: "")
        keys.submenu = sendKeysMenu()
        keys.isEnabled = model.isLive && !model.viewOnly
        menu.addItem(keys)
        let refresh = NSMenuItem.macScreen(L.t("macScreen.toolbar.refresh", "Refresh Screen")) { [weak self] in self?.actions.refresh() }
        refresh.isEnabled = model.isLive
        menu.addItem(refresh)
        return menu
    }

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

    /// Three responsive arrangements keep the primary controls directly reachable.
    /// The pane uses the same height for video, input and state-card geometry.
    func height(for width: CGFloat) -> CGFloat {
        let row = max(Metrics.space8, access.fittingSize.height + Metrics.space2)
        guard controlsShown && width < expandedWidth else { return row }
        let controls = arrangedControls(for: width)
        let available = max(0, width - Metrics.space3 * 2)
        var rows = 1
        var used: CGFloat = 0
        for control in controls {
            let size = min(available, ceil(control.fittingSize.width))
            if used > 0 && used + size > available { rows += 1; used = 0 }
            used += size + Metrics.space2
        }
        return row * CGFloat(rows + 1)
    }

    var expandedWidth: CGFloat {
        let controls = [access, displayButton, quality, sendKeys, refresh, fullScreen, connect, disconnect] as [NSView]
        return controls.filter { $0 !== displayButton || model.displays.count > 1 }
            .reduce(Metrics.space8 * 8) { total, control in
                let width = control === quality ? quality.attributedTitle.size().width + Metrics.space6 : control.fittingSize.width
                return total + width + Metrics.space2
            }
    }

    private func arrangedControls(for width: CGFloat) -> [NSView] {
        let compact = controlsShown && width < expandedWidth - Metrics.space8 * 4
        displayButton.isHidden = !controlsShown || model.displays.count <= 1 || compact
        sendKeys.isHidden = !controlsShown || compact
        refresh.isHidden = !controlsShown || compact
        more.isHidden = !controlsShown || !compact
        return ([access, displayButton, quality, sendKeys, refresh, fullScreen, more, connect, disconnect] as [NSView]).filter { !$0.isHidden }
    }

    override func layout() {
        super.layout()
        let gap = Metrics.space2
        let padding = Metrics.space3
        let rowHeight = max(Metrics.space8, access.fittingSize.height + gap)
        let stacked = controlsShown && bounds.width < expandedWidth
        let compact = stacked && bounds.width < expandedWidth - Metrics.space8 * 4
        line.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        quality.themedToolTip = model.session.map { Self.qualityTitle($0.preferences.quality) }
        let controls = arrangedControls(for: bounds.width)
        let widths = controls.map { ceil($0.fittingSize.width) }
        let controlsWidth = widths.reduce(0, +) + gap * CGFloat(max(0, controls.count - 1))
        let headerRight = stacked ? bounds.width - padding : bounds.width - padding - controlsWidth - gap
        var x = padding
        func place(_ view: NSView, width: CGFloat, y: CGFloat) {
            let h = min(rowHeight, view.fittingSize.height)
            view.frame = CGRect(x: x, y: y + (rowHeight - h) / 2, width: max(0, width), height: h)
            x += width + gap
        }
        dot.frame = CGRect(x: x, y: (rowHeight - Metrics.space2) / 2, width: Metrics.space2, height: Metrics.space2)
        x += Metrics.space2 + gap
        icon.isHidden = compact
        if !icon.isHidden { place(icon, width: icon.intrinsicContentSize.width, y: 0) }
        let statsWidth = min(Self.textWidth(stats), max(0, (headerRight - x) / 2))
        stats.isHidden = !statsSlot
        let remaining = max(0, headerRight - x - (statsSlot ? statsWidth + gap : 0))
        let hintWidth = hint.fittingSize.width
        hint.isHidden = !hintSlot || remaining < Self.textWidth(name) + gap + hintWidth
        let nameWidth = max(0, remaining - (hint.isHidden ? 0 : hintWidth + gap))
        place(name, width: nameWidth, y: 0)
        if statsSlot { place(stats, width: statsWidth, y: 0) }
        if !hint.isHidden { place(hint, width: hintWidth, y: 0) }
        // The release hint remains available on the access control at every width.
        access.themedToolTip = hintSlot ? hint.themedToolTip : access.accessibilityLabel()
        x = stacked ? padding : bounds.width - padding - controlsWidth
        var y: CGFloat = stacked ? rowHeight : 0
        for (control, measured) in zip(controls, widths) {
            let width = min(measured, max(0, bounds.width - padding * 2))
            if stacked && x > padding && x + width > bounds.width - padding { x = padding; y += rowHeight }
            place(control, width: width, y: y)
        }
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
