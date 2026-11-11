import AppKit
import CmuxNextCompat
import CmuxNextDesign

// Which window shows each space (design/spaces.md "The switcher (PR 3)", `sidebar.spaceSwitcher`). Leo 2026-10-29:
// "this could legit make our thing more useful than chrome by having windows be switchable in this way". Leo
// 2026-11-11: "we wanted the different windows to be accessible through spaces, and it's essentially all the same
// window in a way if you want it to be". A click on any space shows it in this window, taking it from the window that
// showed it; it never raises that window, and the tooltip is the space's name alone. A style may draw a hint (a ring,
// a window glyph) on a space another window shows; `plain` draws none.
extension ProfileBarView {
    /// The switcher style in force (`sidebar.spaceSwitcher`, or a gallery's override).
    var switcherStyle: SpaceSwitcherStyle { switcherStyleOverride ?? SpaceSwitcherStyle.tunable.value }

    /// The window showing `profile`, when another one does and the style draws a hint on it.
    func elsewhere(_ profile: SidebarProfile) -> SpaceElsewhere? {
        switcherStyle.marksOtherWindows ? windowMarks.elsewhere[profile.id] : nil
    }

    /// Redraws the marks when another window switches space, a window opens or closes, or the tunable changes.
    /// Stops when the bar leaves its window (`viewDidMoveToWindow` cancels it) or is gone (it holds the bar weakly).
    func observeWindowMarks() -> Task<Void, Never> {
        let marks = windowMarks
        return Task { [weak self] in
            for await _ in ObservationStream({ WindowMarkInputs(marks.elsewhere, marks.windowIsIncognito, SpaceSwitcherStyle.tunable.value) }) {
                guard let self else { return }
                self.refresh()
            }
        }
    }

    // theme-scoped: called only from drawMarks() and the dot drag's snapshots, each inside performWithTheme
    func drawWindowMark(for profile: SidebarProfile, in rect: NSRect, compact: Bool) {
        guard elsewhere(profile) != nil else { return }
        let color = Palette.textPrimary.withAlphaComponent(0.55)
        switch switcherStyle {
        case .ring, .menu:
            // A thin ring just outside the mark, inside the slot's chip (the highlight stays the control's own).
            let mark = compact ? min(Metrics.roomDotDiameter - 2, rect.width - 2) : max(Metrics.roomDotDiameter, Metrics.smallIconSize)
            let side = min(mark + Metrics.space1 * 2, rect.width - 1, rect.height - 1)
            let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side).insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            color.setStroke()
            ring.stroke()
        case .glyph:
            guard !compact else { return }
            let side = Metrics.smallIconSize * 0.6
            let image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side, weight: .semibold))?.tinted(color.withAlphaComponent(1))
            guard let image else { return }
            let size = image.size
            image.draw(in: NSRect(x: rect.midX + Metrics.smallIconSize / 2 - size.width / 2, y: rect.midY - Metrics.smallIconSize / 2 - size.height / 2,
                                  width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: color.alphaComponent)
        case .plain:
            return
        }
    }

    // MARK: Click

    /// What a click on space `index` does (`SpaceSwitcherLogic.click`). Every style acts alike: the hint is drawing only.
    func outcome(_ index: Int) -> SpaceClick {
        let profile = model.profiles[index]
        return SpaceSwitcherLogic.click(profile.id, active: model.activeProfileID, elsewhere: windowMarks.elsewhere[profile.id],
                                        hereIsIncognito: windowMarks.windowIsIncognito, style: switcherStyle)
    }

    /// The press's part of a click: a space this window can show at once shows now. Returns whether it did.
    /// A space another window shows comes here on the release, so a press that drags its dot moves nothing.
    func switchOnPress(_ index: Int) -> Bool {
        guard model.profiles.indices.contains(index), outcome(index) == .switchHere else { return false }
        model.send(.switchProfile(model.profiles[index].id))
        return true
    }

    func click(_ index: Int) {
        let profile = model.profiles[index]
        switch outcome(index) {
        case .none: return
        case .switchHere: model.send(.switchProfile(profile.id))
        case .pullHere: windowMarks.perform?(.moveHere(profile.id))
        case .spaceMenu: showMenu(spaceMenu(), at: index)
        }
    }

    /// a space menu (the `menu` style's current space): every space by name, the current one checked; a pick does what
    /// a click on its dot does (another window's space comes here). New Space and New Incognito Space last.
    func spaceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for profile in model.profiles {
            let current = profile.id == model.activeProfileID
            // The click a dot gets under a style with no menu: the space comes here, or this window switches to it.
            let pulls = SpaceSwitcherLogic.click(profile.id, active: model.activeProfileID, elsewhere: windowMarks.elsewhere[profile.id],
                                                 hereIsIncognito: windowMarks.windowIsIncognito, style: .plain) == .pullHere
            let id = profile.id
            let row = SwitcherMenuItem(title: profile.name) { [weak self] in
                if pulls { self?.windowMarks.perform?(.moveHere(id)) } else if !current { self?.model.send(.switchProfile(id)) }
            }
            row.state = current ? NSControl.StateValue.on : NSControl.StateValue.off
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(SwitcherMenuItem(title: Strings.newProfile) { [weak self] in self?.model.send(.newProfile) })
        menu.addItem(SwitcherMenuItem(title: Strings.newIncognitoSpace) { [weak self] in self?.windowMarks.perform?(.newIncognitoSpace) })
        return menu
    }

    /// Opens `menu` at mark `index` at once (no fade-in), keeping the mark lit and the hover chrome revealed until it closes.
    func showMenu(_ menu: NSMenu, at index: Int) {
        let rects = slotRects()
        guard rects.indices.contains(index) else { return }
        menuOpenIndex = index
        setHovered(index)
        onMenuOpenChange?(true)
        defer {
            menuOpenIndex = nil
            onMenuOpenChange?(false)
            setHovered(isPointerInside ? interactionIndex(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) : nil)
        }
        let slot = rects[index]
        if let presentMenu { return presentMenu(menu, slot) }
        menu.popUp(positioning: nil, at: NSPoint(x: slot.minX, y: slot.minY - Metrics.space1), in: self)
    }
}

/// What the window marks draw from: one value, so a change in any of them redraws once.
private nonisolated struct WindowMarkInputs: Equatable, Sendable {
    let elsewhere: [ProfileKey: SpaceElsewhere]
    let incognito: Bool
    let style: SpaceSwitcherStyle
    init(_ elsewhere: [ProfileKey: SpaceElsewhere], _ incognito: Bool, _ style: SpaceSwitcherStyle) {
        self.elsewhere = elsewhere
        self.incognito = incognito
        self.style = style
    }
}

/// A switcher menu row that runs its handler (AppKit calls menu actions on the main thread).
nonisolated final class SwitcherMenuItem: NSMenuItem {
    /// Nil for a row that only opens its submenu.
    let handler: (@MainActor @Sendable () -> Void)?

    init(title: String, handler: (@MainActor @Sendable () -> Void)?) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc func fire() {
        guard Thread.isMainThread, let handler else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { handler() } // main-proof: guarded by Thread.isMainThread above
    }
}
