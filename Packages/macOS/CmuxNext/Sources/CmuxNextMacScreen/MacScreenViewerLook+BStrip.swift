import AppKit
import CmuxNextCompat
import CmuxNextDesign
import Observation

/// Look B's status strip: one fixed 28 pt row at window-chrome level above the picture. Left, the machine (icon and
/// name), the state beside it only while not live, and the keyboard holder while this Mac's keys go there. Right, while
/// live: the path and latency chip, access (View Only reads as such, in the attention ink), the quality profile, full
/// screen, More and Disconnect; in a state: that state's buttons. A narrow pane drops the release hint, the display
/// picker, the chip, then the menu titles, in that order; the name truncates last.
@MainActor
final class MacScreenStatusStripBar: MacScreenThemedView {
    private let model: MacScreenPaneModel
    /// Follows the model (``ObservationStream``); ends once the view is gone.
    private var watch: Task<Void, Never>?
    private let actions: MacScreenChromeActions
    private let menus: MacScreenToolbarView
    private let icon = MacScreenGlyph("desktopcomputer", font: MacScreenType.body)
    private let name = MacScreenText("", font: MacScreenType.emphasized)
    /// The state beside the name (attributed: it emphasizes the name when the state's title names the machine).
    private let stateLabel = NSTextField(labelWithString: "")
    private let keyboard = MacScreenGlyph("keyboard", font: MacScreenType.caption, ink: \.litGlyph)
    private let releaseHint = MacScreenText(L.t("macScreen.toolbar.releaseHint", "⌃⌥⎋ releases the keyboard"), font: MacScreenType.caption,
                                            ink: \.secondary)
    private let chip = MacScreenFill(\.hover, shape: .rounded(Metrics.controlCornerRadius))
    private let chipText = MacScreenText("", font: MacScreenType.stats, ink: \.secondary)
    private let access: MacScreenMenuButton
    private let accessIcon: MacScreenMenuButton
    private let display: MacScreenMenuButton
    private let quality: MacScreenMenuButton
    private let qualityIcon: MacScreenMenuButton
    private let fullScreen: MacScreenButton
    private let more: MacScreenMenuButton
    private let disconnect: MacScreenButton
    private let line = MacScreenFill(\.separator)
    /// The state's buttons, made again only when the state changes.
    private var stateButtons: [MacScreenButton] = []
    /// The button the keyboard lands on while a state shows (the pane's focus target under this strip): the state's
    /// Return button, else its primary, else its first.
    private(set) var keyButton: MacScreenButton?
    private var shownState: MacScreenStripState?
    private var announced: String?
    private var isFullScreen: Bool?
    private var viewOnlyShown: Bool?

    init(model: MacScreenPaneModel, actions: MacScreenChromeActions, menus: MacScreenToolbarView) {
        self.model = model
        self.actions = actions
        self.menus = menus
        let scope = L.t("macScreen.scope.full", "Full Control")
        access = MacScreenMenuButton(symbol: "cursorarrow", title: scope, accessibilityTitle: scope, id: "macScreen.access")
        accessIcon = MacScreenMenuButton(symbol: "cursorarrow", accessibilityTitle: scope, id: "macScreen.accessCompact")
        display = MacScreenMenuButton(symbol: "display.2", title: "", accessibilityTitle: "", id: "macScreen.display")
        let qualityName = L.t("macScreen.toolbar.quality", "Quality")
        quality = MacScreenMenuButton(symbol: "slider.horizontal.3", title: "", accessibilityTitle: qualityName, id: "macScreen.quality")
        qualityIcon = MacScreenMenuButton(symbol: "slider.horizontal.3", accessibilityTitle: qualityName, id: "macScreen.qualityCompact")
        fullScreen = MacScreenButton(L.t("macScreen.toolbar.fullScreen", "Full Screen"), role: .icon,
                                     symbol: "arrow.up.left.and.arrow.down.right", id: "macScreen.fullScreen") { actions.fullScreen() }
        more = MacScreenMenuButton(symbol: "ellipsis", accessibilityTitle: L.t("macScreen.toolbar.more", "More Controls"), id: "macScreen.more")
        disconnect = MacScreenButton(L.t("macScreen.toolbar.disconnect", "Disconnect"), compact: true, id: "macScreen.disconnect") {
            actions.disconnect()
        }
        super.init(frame: .zero)
        wantsLayer = true
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.maximumNumberOfLines = 1
        stateLabel.wantsLayer = true
        keyboard.themedToolTip = L.t("macScreen.toolbar.keyboardHint", "Keyboard goes to this Mac · ⌃⌥⎋ to release")
        chipText.setAccessibilityIdentifier("macScreen.stats")
        chip.addSubview(chipText)
        chipText.translatesAutoresizingMaskIntoConstraints = true
        for view in [icon, name, stateLabel, keyboard, releaseHint, chip, access, accessIcon, display, quality, qualityIcon, fullScreen, more,
                     disconnect, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        for button in [access, accessIcon] { button.makeMenu = { [weak self] in self?.menus.accessMenu() ?? NSMenu() } }
        for button in [quality, qualityIcon] { button.makeMenu = { [weak self] in self?.menus.qualityMenu() ?? NSMenu() } }
        display.makeMenu = { [weak self] in self?.menus.displayMenu() ?? NSMenu() }
        more.makeMenu = { [weak self] in self?.moreMenu() ?? NSMenu() }
        track()
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFullScreenControl()
    }

    override func colorsChanged() {
        layer?.backgroundColor = colors.chrome.cgColor
        line.isHidden = !colors.borders
        super.colorsChanged()
        renderTitle()
        // The pane's backdrop (the page fill) follows the same colors.
        superview?.needsLayout = true
    }

    // MARK: State

    /// The strip's state while not live (nil: the picture is up and the strip shows the controls).
    private var state: MacScreenStripState? { model.card.map { MacScreenStripState.make($0, model: model) } }

    private func track() {
        // At once for the first frame (the gallery draws in this turn), then on each change.
        apply()
        needsLayout = true
        watch = Task { [weak self] in
            for await _ in ObservationStream({ [weak self] in self?.apply() }) {
                guard let self else { return }
                needsLayout = true
            }
        }
    }

    private func apply() {
        let state = state
        if name.stringValue != model.name { name.stringValue = model.name }
        if state != shownState {
            let revealsLate = shownState == nil && state?.mark == .loading
            shownState = state
            rebuildButtons(for: state)
            renderTitle()
            reveal(late: revealsLate)
            announce(state?.title)
        }
        let session = model.session
        if let session {
            let latency = session.stats.latencyMs.map { String(format: "%.0f ms", $0) } ?? "— ms"
            let path = session.streamPath
            let line = MacScreenToolbarView.statsLine(session)
            let text = session.preferences.showStats ? line : (path == "-" ? latency : "\(path) · \(latency)")
            if chipText.stringValue != text { chipText.stringValue = text }
            // The stats redraw every second: tooltips are set only when they change.
            if chip.themedToolTip != line { chip.themedToolTip = line }
            let title = MacScreenToolbarView.qualityTitle(session.preferences.quality)
            quality.retitle(title)
            for button in [quality, qualityIcon] where button.themedToolTip != title { button.themedToolTip = title }
        }
        display.retitle(String(format: L.t("macScreen.toolbar.displayShort", "Display %d"), model.currentDisplay + 1))
        _ = model.displays.count
        _ = model.capturesKeyboard
        let viewOnly = model.viewOnly
        if viewOnlyShown != viewOnly {
            viewOnlyShown = viewOnly
            let title = viewOnly ? L.t("macScreen.scope.view", "View Only") : L.t("macScreen.scope.full", "Full Control")
            access.retitle(title)
            accessIcon.setAccessibilityLabel(title)
            accessIcon.themedToolTip = title
            for button in [access, accessIcon] {
                button.image = NSImage(systemSymbolName: viewOnly ? "eye" : "cursorarrow", accessibilityDescription: nil)
                button.ink = viewOnly ? \.attention : \.secondary
            }
        }
        applyType()
    }

    /// The labels at the type scale's sizes (a density or font size change shows at once; the views are made once).
    private func applyType() {
        for (label, font) in [(name, MacScreenType.emphasized), (chipText, MacScreenType.stats), (releaseHint, MacScreenType.caption)]
        where label.font != font {
            label.font = font
            for button in [access, accessIcon, display, quality, qualityIcon, more] { button.reloadType() }
            for button in [fullScreen, disconnect] + stateButtons { button.reloadType() }
        }
        icon.resize(to: MacScreenType.body)
        keyboard.resize(to: MacScreenType.caption)
    }

    /// Makes the state's buttons, a keyboard loop like the card's: Tab and Shift-Tab move between them, Space presses the
    /// focused one. A pane that held the keyboard moves it to the new state's key button, or back to the screen once live.
    private func rebuildButtons(for state: MacScreenStripState?) {
        let heldKeyboard = paneHoldsKeyboard
        for button in stateButtons { button.removeFromSuperview() }
        let actions = state?.actions ?? []
        stateButtons = actions.map { action in
            MacScreenButton(action.title, role: action.primary ? .primary : .plain, compact: true, hint: action.returnKey ? .return : nil,
                            id: action.id) { [weak self] in self?.actions.run(action.run) }
        }
        for (index, button) in stateButtons.enumerated() {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.takesKeyFocus = true
            button.nextKeyView = stateButtons[(index + 1) % stateButtons.count]
            addSubview(button)
            paint(button)
        }
        let key = actions.firstIndex { $0.returnKey } ?? actions.firstIndex { $0.primary } ?? actions.indices.first
        keyButton = key.map { stateButtons[$0] }
        if heldKeyboard { self.actions.focusScreen() }
    }

    /// The pane this strip sits in holds the keyboard (its screen, or a button of the strip or the card).
    private var paneHoldsKeyboard: Bool {
        guard let pane = superview, let focused = window?.firstResponder as? NSView else { return false }
        return focused === pane || focused.isDescendant(of: pane)
    }

    /// The state beside the name: its title in the state's ink, the machine's name emphasized inside it when it names it.
    private func renderTitle() {
        guard let state = shownState else {
            stateLabel.attributedStringValue = NSAttributedString()
            return
        }
        let text = NSMutableAttributedString(string: state.title, attributes: [.font: MacScreenType.body, .foregroundColor: colors[keyPath: state.ink]])
        let range = (state.title as NSString).range(of: model.name)
        if !model.name.isEmpty, range.location != NSNotFound {
            text.addAttributes([.font: MacScreenType.emphasized, .foregroundColor: colors.primary], range: range)
        }
        stateLabel.attributedStringValue = text
    }

    /// A transient state's words wait ~300 ms before they show (arch: no extra state for a blink), on the layer's clock.
    private func reveal(late: Bool) {
        guard let layer = stateLabel.layer else { return }
        layer.removeAnimation(forKey: "cmux.stripReveal")
        guard late else { return }
        let fade = Motion.overlays.scheduledFade(.fadeIn, "opacity", from: Float(0), to: Float(1),
                                                 after: MacScreenStatusStrip.revealDelay, on: layer)
        fade.fillMode = .both
        layer.add(fade, forKey: "cmux.stripReveal")
    }

    /// VoiceOver hears a new state once (the strip is the only place it is written).
    private func announce(_ text: String?) {
        guard let text, text != announced else {
            if text == nil { announced = nil }
            return
        }
        announced = text
        NSAccessibility.post(element: stateLabel, notification: .announcementRequested, userInfo: [.announcement: text])
    }

    private func updateFullScreenControl() {
        let expanded = window?.styleMask.contains(.fullScreen) == true
        guard isFullScreen != expanded else { return }
        isFullScreen = expanded
        let title = expanded ? L.t("macScreen.toolbar.exitFullScreen", "Exit Full Screen") : L.t("macScreen.toolbar.fullScreen", "Full Screen")
        fullScreen.setAccessibilityLabel(title)
        fullScreen.themedToolTip = title
        fullScreen.image = NSImage(systemSymbolName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   accessibilityDescription: title)
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.displays.count > 1 {
            let displays = NSMenuItem(title: display.accessibilityLabel() ?? "", action: nil, keyEquivalent: "")
            displays.submenu = menus.displayMenu()
            menu.addItem(displays)
        }
        let keys = NSMenuItem(title: L.t("macScreen.toolbar.sendKeys", "Send Keys"), action: nil, keyEquivalent: "")
        keys.submenu = menus.sendKeysMenu()
        keys.isEnabled = model.canSendKeys
        menu.addItem(keys)
        let refresh = NSMenuItem.macScreen(L.t("macScreen.toolbar.refresh", "Refresh Screen")) { [weak self] in self?.actions.refresh() }
        refresh.isEnabled = model.isLive
        menu.addItem(refresh)
        return menu
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        updateFullScreenControl()
        let height = MacScreenStatusStrip.height
        let controlHeight = MacScreenStatusStrip.controlHeight
        let pad = Metrics.space4
        let gap = Metrics.space2
        line.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)
        let live = shownState == nil && model.showsSessionControls
        let hinted = live && model.capturesKeyboard
        // Right side, in the order a narrowing pane gives items up (the first ones first).
        var right: [NSView] = live ? rightControls() : stateButtons as [NSView]
        let nameFloor = min(64, Self.width(name))
        let leftFixed = pad + icon.intrinsicContentSize.width + gap + nameFloor + (hinted ? keyboard.intrinsicContentSize.width + gap : 0)
        var hint = hinted
        func rightWidth() -> CGFloat { right.reduce(0) { $0 + width(of: $1) + gap } + pad }
        func fits() -> Bool {
            leftFixed + (hint ? Self.width(releaseHint) + gap : 0) + Metrics.space4 + rightWidth() <= bounds.width
        }
        if !fits() { hint = false }
        // Live: the display picker, the chip, then the menus' titles (each keeps its icon twin). A state: its plain buttons.
        let drops: [NSView] = live ? [display, chip, access, quality] : stateButtons.filter { $0.role != .primary } as [NSView]
        for drop in drops where !fits() {
            guard let index = right.firstIndex(where: { $0 === drop }) else { continue }
            right.remove(at: index)
            if drop === access { right.insert(accessIcon, at: index) }
            if drop === quality { right.insert(qualityIcon, at: index) }
        }
        let shown = Set(right.map { ObjectIdentifier($0) })
        for view in ([chip, access, accessIcon, display, quality, qualityIcon, fullScreen, more, disconnect] as [NSView]) + stateButtons {
            view.isHidden = !shown.contains(ObjectIdentifier(view))
        }
        var x = bounds.width - pad
        for view in right.reversed() {
            let w = width(of: view)
            x -= w
            let h = view === chip ? Metrics.space6 + Metrics.space2 : controlHeight
            view.frame = CGRect(x: x, y: ((height - 1 - h) / 2).rounded(), width: w, height: h)
            x -= gap
        }
        if !chip.isHidden {
            let textHeight = ceil(chipText.intrinsicContentSize.height)
            chipText.frame = CGRect(x: Metrics.space3, y: ((chip.bounds.height - textHeight) / 2).rounded(),
                                    width: chip.bounds.width - Metrics.space3 * 2, height: textHeight)
        }
        // Left side, up to the right group with a 4 pt grid gap.
        let leftEdge = right.isEmpty ? bounds.width - pad : x + gap - Metrics.space4
        var lx = pad
        func placeLeft(_ view: NSView, width: CGFloat) {
            let h = ceil(view.fittingSize.height)
            view.frame = CGRect(x: lx, y: ((height - 1 - h) / 2).rounded(), width: max(0, width), height: h)
            lx += width + gap
        }
        placeLeft(icon, width: icon.intrinsicContentSize.width)
        let namedInState = shownState.map { !model.name.isEmpty && $0.title.contains(model.name) } ?? false
        name.isHidden = namedInState
        stateLabel.isHidden = shownState == nil
        keyboard.isHidden = !hinted
        releaseHint.isHidden = !hint
        let tail = (hinted ? keyboard.intrinsicContentSize.width + gap : 0) + (hint ? Self.width(releaseHint) + gap : 0)
        let room = max(0, leftEdge - lx - tail)
        if namedInState {
            placeLeft(stateLabel, width: min(room, Self.width(stateLabel)))
        } else if shownState != nil {
            let nameWidth = min(Self.width(name), max(nameFloor, room / 2))
            placeLeft(name, width: min(nameWidth, room))
            lx += Metrics.space2
            placeLeft(stateLabel, width: min(Self.width(stateLabel), max(0, leftEdge - lx)))
        } else {
            placeLeft(name, width: min(Self.width(name), room))
        }
        if hinted { placeLeft(keyboard, width: keyboard.intrinsicContentSize.width) }
        if hint { placeLeft(releaseHint, width: Self.width(releaseHint)) }
    }

    private func rightControls() -> [NSView] {
        var controls: [NSView] = [chip, access]
        if model.displays.count > 1 { controls.append(display) }
        controls += [quality, fullScreen, more, disconnect]
        return controls
    }

    private func width(of view: NSView) -> CGFloat {
        if view === chip { return Self.width(chipText) + Metrics.space3 * 2 }
        if view is MacScreenMenuButton, view !== more, view !== accessIcon, view !== qualityIcon {
            return ceil(view.fittingSize.width + Metrics.space3)
        }
        return ceil(max(view.fittingSize.width, view is MacScreenMenuButton ? MacScreenStatusStrip.controlHeight : 0))
    }

    /// A one-line label's whole width.
    private static func width(_ label: NSTextField) -> CGFloat { MacScreenToolbarView.textWidth(label) }
}
