import AppKit
import CmuxNextDesign
import CmuxNextDevices
import CmuxScreenKit
import Observation

/// The Mac's name, who started the view when an agent did, measured latency and
/// session controls. Wide panes use one row, medium panes separate status and
/// controls, and narrow panes put secondary commands in More. Observation
/// updates the existing views.
@MainActor
final class MacScreenToolbarView: MacScreenThemedView {
    private let model: MacScreenPaneModel
    private let actions: MacScreenChromeActions
    private let dot = MacScreenFill(\.tertiary, shape: .circle)
    private let icon = MacScreenGlyph("desktopcomputer", font: MacScreenType.body)
    private let name = MacScreenText("", font: MacScreenType.emphasized)
    /// "Started by …" beside the name while an agent's start shows (the name's tooltip says it at any width).
    private let starter = MacScreenText("", font: MacScreenType.caption, ink: \.secondary)
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
    private let record: MacScreenMenuButton
    private var recordShowsActive: Bool?
    private let refresh: MacScreenButton
    private let connect: MacScreenButton
    private let disconnect: MacScreenButton
    /// Disconnect as a close glyph, for the glyphs bar (``MacScreenToolbarBar/icons``).
    private let disconnectGlyph: MacScreenButton
    private let line = MacScreenFill(\.separator)
    /// Slots shown now (the stats and hint slots exist while their condition holds, whether or not they fit).
    private var statsSlot = false
    /// The bar's stats line in full and without codec and size (``statsLine(_:)``): the layout shows the full one only
    /// beside the whole name, so the name and the rate never truncate for the codec. Nil: the stats slot shows one text.
    private var statsLines: (full: String, short: String, room: CGFloat)?
    private var hintSlot = false
    private var starterSlot = false
    private var controlsShown = false
    private var accessIsViewOnly: Bool?
    private var reportedHeight: CGFloat?
    private var isFullScreen: Bool?
    /// The viewer look whose material the toolbar was painted in (nil: not yet).
    private var paintedLook: MacScreenViewerLook?
    /// The look's material behind the controls (``MacScreenViewerStyle/makeToolbarSurface``) and the look it was made for.
    private var surface: NSView?
    private var surfaceLook: MacScreenViewerLook?
    /// The pill layout (``MacScreenViewerStyle/ToolbarLayout/pill``): one row, the secondary controls in More.
    private var isPill: Bool { model.viewerLook.style.toolbarLayout == .pill }
    /// How a floating bar arranges its controls (``MacScreenToolbarBar``); a docked toolbar or a pill keeps its own.
    private var bar: MacScreenToolbarBar {
        let style = model.viewerLook.style
        return style.toolbarPlacement == .floating && style.toolbarLayout != .pill ? model.toolbarBar : .stacked
    }
    /// Look A's auto-hide faded the toolbar out (``MacScreenViewerOverlay``): it stays hidden so clicks reach the picture.
    var autoHidden = false {
        didSet { syncHidden() }
    }

    /// Whether the selected look hides the toolbar now: under look B's strip (it carries the state and the controls), a
    /// pill anywhere but over a live picture, or a toolbar look A's auto-hide faded out. The toolbar's own state and the
    /// pane's layout both set ``isHidden`` from here, so neither undoes the other.
    var hiddenByLook: Bool {
        let style = model.viewerLook.style
        if style.statusStrip || autoHidden { return true }
        return style.toolbarLayout == .pill && !(model.showsSessionControls && model.isLive)
    }

    func syncHidden() {
        let hidden = hiddenByLook
        if isHidden != hidden { isHidden = hidden }
    }
    /// The pill's width the pane last laid out (nil: not a pill).
    private var reportedWidth: CGFloat?
    /// The look's View | Control segments, in place of `access` when it asks (``MacScreenViewerStyle/toolbarScopeSegments``).
    private lazy var segments = MacScreenScopeSegments { [weak self] scope in self?.actions.requestScope(scope) }
    private var scopeControl: NSView { model.viewerLook.style.toolbarScopeSegments ? segments : access }

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
        record = MacScreenMenuButton(symbol: "record.circle", accessibilityTitle: L.t("macScreen.record.title", "Record Screen"), id: "macScreen.record")
        refresh = MacScreenButton(L.t("macScreen.toolbar.refresh", "Refresh Screen"), role: .icon, symbol: "arrow.clockwise") { actions.refresh() }
        refresh.themedToolTip = L.t("macScreen.toolbar.refresh", "Refresh Screen")
        connect = MacScreenButton(L.t("macScreen.toolbar.connect", "Connect"), role: .primary, compact: true, id: "macScreen.connect") {
            actions.connect()
        }
        disconnect = MacScreenButton(L.t("macScreen.toolbar.disconnect", "Disconnect"), compact: true, id: "macScreen.disconnect") {
            actions.disconnect()
        }
        disconnectGlyph = MacScreenButton(L.t("macScreen.toolbar.disconnect", "Disconnect"), role: .icon, symbol: "xmark",
                                          id: "macScreen.disconnectGlyph") { actions.disconnect() }
        disconnectGlyph.themedToolTip = L.t("macScreen.toolbar.disconnect", "Disconnect")
        super.init(frame: .zero)
        wantsLayer = true
        stats.setAccessibilityIdentifier("macScreen.stats")
        starter.setAccessibilityIdentifier("macScreen.startedBy")
        for view in [dot, icon, name, starter, stats, access, segments, hint, displayButton, quality, sendKeys, record, refresh, fullScreen, more, connect, disconnect, disconnectGlyph, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        displayButton.makeMenu = { [weak self] in self?.displayMenu() ?? NSMenu() }
        quality.makeMenu = { [weak self] in self?.qualityMenu() ?? NSMenu() }
        sendKeys.makeMenu = { [weak self] in self?.sendKeysMenu() ?? NSMenu() }
        record.makeMenu = { [weak self] in self?.recordMenu() ?? NSMenu() }
        access.makeMenu = { [weak self] in self?.accessMenu() ?? NSMenu() }
        more.makeMenu = { [weak self] in self?.moreMenu() ?? NSMenu() }
        track()
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFullScreenControl()
    }

    private func updateFullScreenControl() {
        let expanded = window?.styleMask.contains(.fullScreen) == true
        guard isFullScreen != expanded else { return }
        isFullScreen = expanded
        let title = expanded ? L.t("macScreen.toolbar.exitFullScreen", "Exit Full Screen") : L.t("macScreen.toolbar.fullScreen", "Full Screen")
        fullScreen.setAccessibilityLabel(title)
        fullScreen.themedToolTip = title
        fullScreen.image = NSImage(systemSymbolName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: title)
    }

    override func colorsChanged() {
        let style = model.viewerLook.style
        paintedLook = model.viewerLook
        layer?.backgroundColor = (style.toolbarFilled ? colors.chrome : NSColor.clear).cgColor
        layer?.cornerRadius = style.toolbarLayout == .pill ? Metrics.capsuleRadius(bounds.size) : style.toolbarCornerRadius
        layer?.cornerCurve = .continuous
        if let make = style.makeToolbarSurface, surfaceLook != model.viewerLook {
            surfaceLook = model.viewerLook
            surface?.removeFromSuperview()
            surface = make()
            if let surface {
                surface.frame = bounds
                surface.autoresizingMask = [.width, .height]
                addSubview(surface, positioned: .below, relativeTo: nil)
            }
        }
        line.isHidden = !colors.borders || style.toolbarPlacement == .floating
        if style.makeToolbarSurface == nil {
            surfaceLook = nil
            surface?.removeFromSuperview()
            surface = style.toolbarSurface?(style.toolbarCornerRadius)
            if let surface { surface.frame = bounds; addSubview(surface, positioned: .below, relativeTo: nil) }
        }
        super.colorsChanged()
    }

    // MARK: State

    /// Shows the model's state; again on every change of a value read here.
    private func track() {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        needsLayout = true
        let height = height(for: bounds.width)
        // A floating toolbar's width follows what it shows (the stats, the keyboard hint, Reconnect): the pane centres it again.
        let width = model.viewerLook.style.toolbarPlacement == .floating ? floatingWidth : nil
        if reportedHeight != height || reportedWidth != width {
            reportedHeight = height
            reportedWidth = width
            superview?.needsLayout = true
        }
    }

    /// The device's name, then a run link's name, or that its display is gone (the host shows its main display).
    static func title(_ model: MacScreenPaneModel) -> String {
        var parts = [model.name]
        if model.session?.linkedDisplayGone == true {
            parts.append(L.t("macScreen.run.displayGone", "That run's display is gone; showing the main display"))
        } else if let run = model.runName {
            parts.append(run)
        }
        return parts.joined(separator: " · ")
    }

    private func apply() {
        applyType()
        // A look change repaints the material; the pane lays the toolbar out again.
        if paintedLook != model.viewerLook {
            colorsChanged()
            superview?.needsLayout = true
        }
        dot.fill = statusColor
        let title = Self.title(model)
        if name.stringValue != title { name.stringValue = title }
        let startedBy = model.startedBy?.label
        starterSlot = startedBy != nil
        if starter.stringValue != startedBy ?? "" { starter.stringValue = startedBy ?? "" }
        setThemedTip(startedBy, on: name)
        let session = model.session
        let live = model.isLive
        statsSlot = session != nil && live
        statsLines = nil
        if statsSlot, let session {
            // A pill keeps to the latency, and says a brief outage there quietly (the picture stays up); the full
            // stats line is the bar's.
            let inline = model.qualityReadout == .inline
            if session.preferences.showStats && !isPill {
                let lines = Self.statsLines(session, rate: inline)
                statsLines = lines
                stats.stringValue = lines.full
            } else if isPill && model.isQuietOutage {
                stats.stringValue = L.t("macScreen.card.reconnecting", "Reconnecting…")
            } else {
                // Inline readout (R1): the pill leads with the rate the host streams at (D10), then the round trip.
                let latency = session.stats.latencyMs.map { String(format: "%.0f ms", $0) } ?? "— ms"
                stats.stringValue = inline ? Self.pillLine(session.stats) : latency
            }
        }
        let viewOnly = model.viewOnly
        if accessIsViewOnly != viewOnly {
            accessIsViewOnly = viewOnly
            access.retitle(viewOnly ? L.t("macScreen.scope.view", "View Only") : L.t("macScreen.scope.full", "Full Control"))
            access.image = NSImage(systemSymbolName: viewOnly ? "eye" : "cursorarrow", accessibilityDescription: nil)
            access.ink = viewOnly ? \.attention : \.secondary
            segments.select(viewOnly ? .view : .full)
        }
        hintSlot = model.capturesKeyboard && live
        controlsShown = model.showsSessionControls
        let pill = isPill
        let bar = self.bar
        segments.showsTitles = bar != .icons
        // The controls-only bar shows no name: the status dot carries it.
        setThemedTip(bar == .controls ? title : nil, on: dot)
        // A pill floats only over a live picture: every other state takes the pane with its own actions.
        syncHidden()
        access.isHidden = !controlsShown || scopeControl !== access
        segments.isHidden = !controlsShown || scopeControl !== segments
        access.isEnabled = controlsShown
        fullScreen.isHidden = !controlsShown || pill
        more.isHidden = !controlsShown
        if let session {
            // Quality chip readout (R2): the button says the rate while live, in attention when the stream strains.
            // A one-row bar never says "Auto": it says the rate while the host sends one, else the glyph alone.
            let rated = bar == .row || bar == .controls || model.qualityReadout == .chip
            let chip = rated && bar != .icons && live ? session.stats.hostKbps : nil
            let idle = bar.oneRow ? "" : Self.qualityTitle(session.preferences.quality)
            quality.retitle(chip.map { MacScreenQualityReadout.rateText(kbps: $0, profile: session.stats.encodeProfile) } ?? idle)
            let ink: KeyPath<MacScreenColors, NSColor> = chip != nil && MacScreenQualityReadout.isStrained(session.stats) ? \.attention : \.secondary
            if quality.ink != ink { quality.ink = ink }
        }
        let displayCount = model.displays.count
        displayButton.retitle(String(format: L.t("macScreen.toolbar.displayShort", "Display %d"), model.currentDisplay + 1))
        displayButton.isHidden = !controlsShown || displayCount <= 1 || pill
        quality.isHidden = !controlsShown
        let canSend = model.canSendKeys
        // A one-row bar keeps Send Keys and Refresh in More.
        sendKeys.isHidden = !controlsShown || pill || bar.oneRow
        sendKeys.isEnabled = canSend
        sendKeys.ink = canSend ? \.secondary : \.tertiary
        setThemedTip(viewOnly
            ? L.t("macScreen.toolbar.sendKeysViewOnly", "Send Keys is off in a View Only session")
            : L.t("macScreen.toolbar.sendKeys", "Send Keys"), on: sendKeys)
        applyRecord(live: live)
        refresh.isHidden = !controlsShown || pill || bar.oneRow
        refresh.isEnabled = live
        let ended: Bool = switch session?.phase {
        case .ended?, .failed?: true
        default: false
        }
        connect.isHidden = !controlsShown || !ended
        disconnect.isHidden = !controlsShown || ended || bar == .icons
        disconnectGlyph.isHidden = !controlsShown || ended || bar != .icons
    }

    /// The labels, glyphs and buttons at the type scale's sizes, read here so a density, font size
    /// or interface scale change shows at once (the views are made once).
    private func applyType() {
        let fonts: [(MacScreenText, NSFont)] = [(name, MacScreenType.emphasized), (stats, MacScreenType.stats),
                                                (hintText, MacScreenType.caption), (starter, MacScreenType.caption)]
        var changed = false
        for (label, font) in fonts where label.font != font {
            label.font = font
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        icon.resize(to: MacScreenType.body)
        hintGlyph.resize(to: MacScreenType.caption)
        guard changed else { return }
        for button in [access, displayButton, quality, sendKeys, record, more] { button.reloadType() }
        for button in [refresh, fullScreen, connect, disconnect, disconnectGlyph] { button.reloadType() }
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
        return statsLine(path: session.streamPath, kbps: stats.hostKbps, profile: stats.encodeProfile, fps: stats.fps,
                         targetFps: stats.targetFps, latencyMs: stats.latencyMs, encoding: stats.encoding,
                         frameSize: session.frameSize)
    }

    /// The pill's inline readout: the host's rate and the round trip (`148 Mbps · 3 ms`); the round trip alone until the
    /// host reports a rate.
    static func pillLine(_ stats: MacScreenSession.LiveStats) -> String {
        let latency = stats.latencyMs.map { String(format: "%.0f ms", $0) } ?? "— ms"
        guard let kbps = stats.hostKbps else { return latency }
        return "\(MacScreenQualityReadout.rateText(kbps: kbps, profile: stats.encodeProfile)) · \(latency)"
    }

    /// The stats line in full and short (no codec, no size), and the room the full one takes with every number at three
    /// digits, so a floating toolbar sized for it does not move as the numbers change.
    /// `rate`: the line leads with the host's rate (the inline readout).
    static func statsLines(_ session: MacScreenSession, rate: Bool = false) -> (full: String, short: String, room: CGFloat) {
        let stats = session.stats
        let kbps = rate ? stats.hostKbps : nil
        let profile = stats.encodeProfile
        let full = statsLine(path: session.streamPath, kbps: kbps, profile: profile, fps: stats.fps,
                             targetFps: stats.targetFps, latencyMs: stats.latencyMs, encoding: stats.encoding,
                             frameSize: session.frameSize)
        let short = statsLine(path: session.streamPath, kbps: kbps, profile: profile, fps: stats.fps,
                              targetFps: stats.targetFps, latencyMs: stats.latencyMs, encoding: "-", frameSize: .zero)
        let widest = statsLine(path: session.streamPath, kbps: kbps.map { _ in 888_000 }, profile: profile, fps: 888,
                               targetFps: stats.targetFps.map { _ in 888 }, latencyMs: 888, encoding: stats.encoding,
                               frameSize: session.frameSize)
        return (full, short, max(textWidth(full, font: MacScreenType.stats), textWidth(widest, font: MacScreenType.stats)))
    }

    /// The stats line: path, the host's rate when given ("148 Mbps"), frame rate (measured, then the rate the Mac
    /// streams at when it says: "118/120 fps"), round trip, codec, size.
    static func statsLine(path: String, kbps: Double? = nil, profile: String? = nil, fps: Double, targetFps: Int?, latencyMs: Double?, encoding: String,
                          frameSize: CGSize) -> String {
        let measured = fps.isFinite ? Int(fps.rounded()) : 0
        let rate = targetFps.map { target in
            L.t("macScreen.stats.fpsOfTarget", "\(measured)/\(target) fps")
        } ?? String(format: "%.0f fps", fps)
        var parts = [path]
        if let kbps { parts.append(MacScreenQualityReadout.rateText(kbps: kbps, profile: profile)) }
        parts.append(rate)
        if let rtt = latencyMs { parts.append(String(format: "%.0f ms", rtt)) }
        if encoding != "-" { parts.append(encoding) }
        if frameSize.width >= 1 { parts.append("\(Int(frameSize.width))×\(Int(frameSize.height))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Menus

    func accessMenu() -> NSMenu {
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
        let pill = isPill
        if model.displays.count > 1 {
            let displays = NSMenuItem(title: displayButton.accessibilityLabel() ?? "", action: nil, keyEquivalent: "")
            displays.submenu = displayMenu()
            menu.addItem(displays)
        }
        let keys = NSMenuItem(title: L.t("macScreen.toolbar.sendKeys", "Send Keys"), action: nil, keyEquivalent: "")
        keys.submenu = sendKeysMenu()
        keys.isEnabled = model.canSendKeys
        menu.addItem(keys)
        let refresh = NSMenuItem.macScreen(L.t("macScreen.toolbar.refresh", "Refresh Screen")) { [weak self] in self?.actions.refresh() }
        refresh.isEnabled = model.isLive
        menu.addItem(refresh)
        if record.isHidden {
            // A compact bar folds Record into More with the rest.
            let recordItem = NSMenuItem(title: L.t("macScreen.record.title", "Record Screen"), action: nil, keyEquivalent: "")
            recordItem.submenu = recordMenu()
            menu.addItem(recordItem)
        }
        if pill {
            // The pill's More also holds what the bar shows as buttons: Full Screen.
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.macScreen(fullScreen.accessibilityLabel() ?? L.t("macScreen.toolbar.fullScreen", "Full Screen")) { [weak self] in
                self?.actions.fullScreen()
            })
        }
        return menu
    }

    func displayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, size) in model.displays.enumerated() {
            let title = String(format: L.t("macScreen.toolbar.display", "Display %d (%d × %d)"), index + 1, Int(size.width), Int(size.height))
            menu.addItem(NSMenuItem.macScreen(title, checked: model.currentDisplay == index) { [weak self] in self?.actions.selectDisplay(index) })
        }
        return menu
    }

    func qualityMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let session = model.session else { return menu }
        if model.qualityReadout == .chip, model.isLive {
            // The quality chip's readout: every number first, then the choices.
            for row in MacScreenQualityReadout.rows(session.stats, frameSize: session.frameSize, path: session.streamPath) {
                let item = NSMenuItem(title: "\(row.label)\t\(row.value)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        } else if session.phase == .connected {
            // The whole stats line first, codec and frame size included: the bar's label drops them when it is short
            // of room and shows no tooltip (a control that shows text has none), so its own control says them (Chief,
            // 2026-11-21: what the cut tooltip said shows somewhere visible).
            let stats = NSMenuItem(title: Self.statsLines(session).full, action: nil, keyEquivalent: "")
            stats.isEnabled = false
            menu.addItem(stats)
            menu.addItem(.separator())
        }
        for quality in ScreenQuality.allCases {
            menu.addItem(NSMenuItem.macScreen(Self.qualityTitle(quality), checked: session.preferences.quality == quality) { [weak self] in
                self?.actions.setQuality(quality)
            })
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.toolbar.showStats", "Show Stats"), checked: session.preferences.showStats) { [weak self] in
            self?.actions.toggleStats()
        })
        addCustomize(to: menu, session.preferences)
        return menu
    }

    /// The Quality menu's Customize part: a bitrate cap and the cursor in the stream. Each
    /// change starts a new session, as a quality or display change does.
    private func addCustomize(to menu: NSMenu, _ preferences: ScreenPreferences) {
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: L.t("macScreen.customize.title", "Customize")))
        let bitrate = NSMenuItem(title: L.t("macScreen.customize.bitrate", "Bitrate Cap"), action: nil, keyEquivalent: "")
        let caps = NSMenu()
        caps.autoenablesItems = false
        for kbps in ScreenPreferences.maxKbpsChoices {
            caps.addItem(NSMenuItem.macScreen(Self.bitrateTitle(kbps), checked: preferences.maxKbps == kbps) { [weak self] in
                self?.actions.setMaxKbps(kbps)
            })
        }
        bitrate.submenu = caps
        menu.addItem(bitrate)
        menu.addItem(NSMenuItem.macScreen(L.t("macScreen.customize.showCursor", "Show Cursor in Stream"),
                                          checked: preferences.showCursorInStream) { [weak self] in
            self?.actions.toggleStreamCursor()
        })
    }

    static func bitrateTitle(_ kbps: Int?) -> String {
        guard let kbps else { return L.t("macScreen.customize.bitrateAuto", "Auto") }
        return String(format: L.t("macScreen.customize.bitrateMbps", "%d Mbps"), kbps / 1000)
    }

    func sendKeysMenu() -> NSMenu {
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

    /// Record: red while a file is being written; its menu starts or stops
    /// it and shows the newest file in Finder.
    private func applyRecord(live: Bool) {
        let recording = model.recording
        let active = recording.isRecording
        record.isHidden = !controlsShown
        record.isEnabled = active || (live && recording.canRecord) || recording.lastFile != nil
        if recordShowsActive != active {
            recordShowsActive = active
            record.image = NSImage(systemSymbolName: active ? "record.circle.fill" : "record.circle", accessibilityDescription: nil)
            record.ink = active ? \.danger : \.secondary
        }
        setThemedTip(recording.failed
            ? L.t("macScreen.record.failed", "The recording could not be saved")
            : active ? L.t("macScreen.record.stop", "Stop Recording") : L.t("macScreen.record.title", "Record Screen"), on: record)
    }

    private func recordMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let recording = model.recording
        let toggle = NSMenuItem.macScreen(recording.isRecording
            ? L.t("macScreen.record.stop", "Stop Recording")
            : L.t("macScreen.record.start", "Start Recording")) { [weak self] in self?.actions.toggleRecording() }
        toggle.isEnabled = recording.isRecording || (model.isLive && recording.canRecord)
        menu.addItem(toggle)
        let show = NSMenuItem.macScreen(L.t("macScreen.record.showInFinder", "Show Recording in Finder")) { [weak self] in
            self?.actions.showRecording()
        }
        show.isEnabled = recording.file != nil || recording.lastFile != nil
        menu.addItem(show)
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
        let row = model.viewerLook.style.toolbarRowHeight ?? max((Metrics.space6 * 2), access.fittingSize.height + Metrics.space2)
        guard controlsShown && width < expandedWidth && !isPill && !bar.oneRow else { return row }
        let controls = arrangedControls(for: width)
        let available = max(0, width - Metrics.space3 * 2)
        var rows = 1
        var used: CGFloat = 0
        for control in controls {
            let size = min(available, controlWidth(control))
            if used > 0 && used + size > available { rows += 1; used = 0 }
            used += size + Metrics.space2
        }
        return row * CGFloat(rows + 1)
    }

    var expandedWidth: CGFloat {
        if isPill { return pillWidth }
        if bar.oneRow { return oneRowWidth }
        let controls = [scopeControl, displayButton, quality, sendKeys, record, refresh, fullScreen, connect, disconnect] as [NSView]
        return controls.filter { $0 !== displayButton || model.displays.count > 1 }
            .reduce((Metrics.space6 * 2) * 9) { total, control in
                total + controlWidth(control) + Metrics.space2
            }
    }

    /// Reserve each menu's longest localized choice so choosing access or quality never moves
    /// the responsive breakpoint. Icon allowances are fixed even when the access glyph changes.
    private func controlWidth(_ control: NSView) -> CGFloat {
        let titles: [String]
        if control === access {
            titles = [L.t("macScreen.scope.view", "View Only"), L.t("macScreen.scope.full", "Full Control")]
        } else if control === quality, bar.oneRow {
            // A one-row bar's Quality is its glyph, or the rate in room for three digits so the bar never moves.
            guard quality.hasTitle else { return ceil(quality.fittingSize.width) }
            let profile = model.session?.stats.encodeProfile
            titles = [MacScreenQualityReadout.rateText(kbps: 888_000, profile: profile)]
        } else if control === quality {
            titles = ScreenQuality.allCases.map(Self.qualityTitle)
        } else {
            return ceil(control.fittingSize.width)
        }
        let textWidth = titles.map { NSAttributedString(string: $0, attributes: [.font: MacScreenType.body]).size().width }.max() ?? 0
        return ceil(textWidth + Metrics.space6 + Metrics.space2)
    }

    /// The pill's width: its padding, the status dot, the icon, the name (at most a few words wide), room for a
    /// latency, the keyboard hint while this Mac's keys go to the screen, and its controls. The latency's room is
    /// fixed so the pill does not move as the number changes.
    private var pillWidth: CGFloat {
        let gap = Metrics.space2
        let nameRoom = min(Self.textWidth(name), ceil(MacScreenType.body.pointSize * 16))
        var room = model.session?.stats ?? MacScreenSession.LiveStats()
        let rated = model.qualityReadout == .inline && room.hostKbps != nil
        room.hostKbps = rated ? 888_000 : nil
        room.latencyMs = 888
        let roomText = Self.pillLine(room)
        let latencyRoom = statsSlot ? max(Self.textWidth(stats), ceil(NSAttributedString(string: roomText, attributes: [.font: MacScreenType.stats]).size().width) + 4) + gap : 0
        let hintRoom = hintSlot ? hint.fittingSize.width + gap : 0
        let controls = pillControls
        let controlsRoom = controls.reduce(0) { $0 + controlWidth($1) + gap }
        return ceil(Metrics.space3 * 2 + Metrics.space2 + gap + icon.intrinsicContentSize.width + gap + nameRoom + gap + latencyRoom
            + hintRoom + controlsRoom)
    }

    /// A floating bar's width (look A): room for the whole name, the full stats line, the keyboard hint and the
    /// controls side by side, so the name and stats never truncate beside empty space. The pane caps it at its own
    /// width; below the full width the layout drops the codec and size first. A pill keeps ``expandedWidth``.
    var floatingWidth: CGFloat {
        guard !isPill else { return expandedWidth }
        if bar.oneRow { return oneRowWidth }
        let gap = Metrics.space2
        let nameRoom = min(Self.textWidth(name), ceil(MacScreenType.body.pointSize * 16))
        let statsRoom = statsSlot ? (statsLines?.room ?? Self.textWidth(stats)) + gap : 0
        let hintRoom = hintSlot ? hint.fittingSize.width + gap : 0
        let header = Metrics.space3 * 2 + Metrics.space2 + gap + icon.intrinsicContentSize.width + gap + nameRoom + gap + statsRoom + hintRoom
        // ``expandedWidth`` is the controls' room plus a fixed allowance for the header: the header's own room instead.
        let allowance = (Metrics.space6 * 2) * 8
        return ceil(expandedWidth + max(0, header - allowance))
    }

    /// A one-row bar's whole width: its header (none but the dot for the controls-only bar) and its controls, the
    /// display picker while there is more than one display. The pane caps it at its own width; the layout folds the
    /// display picker into More, then hides the icon, then truncates the name.
    private var oneRowWidth: CGFloat {
        let gap = Metrics.space2
        var header = Metrics.space3 * 2 + Metrics.space2 + gap
        if bar != .controls {
            let nameRoom = min(Self.textWidth(name), ceil(MacScreenType.body.pointSize * 16))
            let statsRoom = statsSlot ? (statsLines?.room ?? Self.textWidth(stats)) + gap : 0
            let hintRoom = hintSlot ? hint.fittingSize.width + gap : 0
            header += icon.intrinsicContentSize.width + gap + nameRoom + gap + statsRoom + hintRoom
        }
        let controls = oneRowControls.filter { $0 !== displayButton || model.displays.count > 1 }
        return ceil(header + controls.reduce(0) { $0 + controlWidth($1) + gap })
    }

    /// A one-row bar's controls, every one it may show; Connect and Disconnect take turns in one place.
    private var oneRowControls: [NSView] {
        let ended = !connect.isHidden
        let leave: NSView = ended ? connect : (bar == .icons ? disconnectGlyph : disconnect)
        return [scopeControl, displayButton, quality, record, fullScreen, more, leave]
    }

    /// The pill's controls: access (View Only shows as such), quality, Record, More, Connect or Disconnect.
    private var pillControls: [NSView] { ([access, quality, record, more, connect, disconnect] as [NSView]).filter { !$0.isHidden } }

    private func arrangedControls(for width: CGFloat) -> [NSView] {
        if isPill {
            more.isHidden = !controlsShown
            return pillControls
        }
        if bar.oneRow {
            sendKeys.isHidden = true
            refresh.isHidden = true
            more.isHidden = !controlsShown
            // Too narrow for everything: the display picker goes to More first.
            displayButton.isHidden = !controlsShown || model.displays.count <= 1 || width < oneRowWidth
            return ([scopeControl, displayButton, quality, fullScreen, more, connect, disconnect, disconnectGlyph] as [NSView]).filter { !$0.isHidden }
        }
        let compact = controlsShown && width < expandedWidth - (Metrics.space6 * 2) * 4
        displayButton.isHidden = !controlsShown || model.displays.count <= 1 || compact
        sendKeys.isHidden = !controlsShown || compact
        refresh.isHidden = !controlsShown || compact
        record.isHidden = !controlsShown || compact
        more.isHidden = !controlsShown || !compact
        return ([scopeControl, displayButton, quality, sendKeys, record, refresh, fullScreen, more, connect, disconnect] as [NSView]).filter { !$0.isHidden }
    }

    override func layout() {
        super.layout()
        // Native full-screen transitions resize the window and lay out its contents.
        updateFullScreenControl()
        let gap = Metrics.space2
        let padding = Metrics.space3
        let rowHeight = model.viewerLook.style.toolbarRowHeight ?? max((Metrics.space6 * 2), access.fittingSize.height + gap)
        let pill = isPill
        let bar = self.bar
        let bare = bar == .controls
        let stacked = !pill && !bar.oneRow && controlsShown && bounds.width < expandedWidth
        let compact = stacked && bounds.width < expandedWidth - (Metrics.space6 * 2) * 4
        if pill {
            let radius = Metrics.capsuleRadius(bounds.size)
            layer?.cornerRadius = radius
            (surface as? OverlaySurfaceView)?.cornerRadius = radius
        }
        line.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        quality.themedToolTip = model.session.map { Self.qualityTitle($0.preferences.quality) }
        let controls = arrangedControls(for: bounds.width)
        let widths = controls.map(controlWidth)
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
        // A one-row bar too narrow for its whole width drops the icon before the name truncates.
        icon.isHidden = compact || bare || (bar.oneRow && bounds.width < oneRowWidth)
        if !icon.isHidden { place(icon, width: icon.intrinsicContentSize.width, y: 0) }
        if let lines = statsLines {
            // The whole name and the rate come before the codec and size: the full line only when both fit.
            let fits = Self.textWidth(lines.full, font: MacScreenType.stats) + gap + Self.textWidth(name) <= headerRight - x
            let text = fits ? lines.full : lines.short
            if stats.stringValue != text { stats.stringValue = text }
        }
        // The name keeps its whole width up to half the header; the stats take the rest.
        let nameFloor = min(Self.textWidth(name), max(0, (headerRight - x) / 2))
        let statsWidth = min(Self.textWidth(stats), max(0, headerRight - x - nameFloor - gap))
        stats.isHidden = !statsSlot || bare
        name.isHidden = bare
        var remaining = max(0, headerRight - x - (statsSlot ? statsWidth + gap : 0))
        // Who started the view comes before the release hint; each shows only where the whole name still fits.
        let starterWidth = Self.textWidth(starter)
        starter.isHidden = !starterSlot || bare || remaining < Self.textWidth(name) + gap + starterWidth
        if !starter.isHidden { remaining -= starterWidth + gap }
        let hintWidth = hint.fittingSize.width
        hint.isHidden = !hintSlot || bare || remaining < Self.textWidth(name) + gap + hintWidth
        let nameWidth = max(0, remaining - (hint.isHidden ? 0 : hintWidth + gap))
        if !bare { place(name, width: nameWidth, y: 0) }
        if !starter.isHidden { place(starter, width: starterWidth, y: 0) }
        if statsSlot && !bare { place(stats, width: statsWidth, y: 0) }
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

    /// A one-line string's width in `font`, with the same slack as a label's.
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width + 4)
    }
}

extension MacScreenColors {
}
