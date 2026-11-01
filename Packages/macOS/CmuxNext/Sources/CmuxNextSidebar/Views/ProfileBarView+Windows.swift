import AppKit
import CmuxNextCompat
import CmuxNextDesign

// Which window shows each space (design/spaces.md "The switcher (PR 3)", `sidebar.spaceSwitcher`). Leo 2026-10-29:
// "this could legit make our thing more useful than chrome by having windows be switchable in this way". A space
// another window shows carries a mark (a ring, or a window glyph); clicking it offers Go to Window or Move Here, and
// Option-click goes to that window. The dots strip itself is unchanged; `plain` is today's strip.
extension ProfileBarView {
    /// The switcher style in force (`sidebar.spaceSwitcher`, or a gallery's override).
    var switcherStyle: SpaceSwitcherStyle { switcherStyleOverride ?? SpaceSwitcherStyle.tunable.value }

    /// The window showing `profile`, when another one does and the style marks it.
    func elsewhere(_ profile: SidebarProfile) -> SpaceElsewhere? {
        switcherStyle.marksOtherWindows ? model.spacesElsewhere[profile.id] : nil
    }

    /// Redraws the marks when another window switches space, a window opens or closes, or the tunable changes.
    /// Stops when the bar leaves its window (`viewDidMoveToWindow` cancels it) or is gone (it holds the bar weakly).
    func observeWindowMarks() -> Task<Void, Never> {
        let model = model
        return Task { [weak self] in
            for await _ in ObservationStream({ WindowMarkInputs(model.spacesElsewhere, model.windowIsIncognito, SpaceSwitcherStyle.tunable.value) }) {
                guard let self else { return }
                self.refresh()
            }
        }
    }

    // theme-scoped: called only from drawMarks() inside performWithTheme
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

    /// A mark's tooltip and VoiceOver label: says so when another window shows the space.
    func windowMarkLabel(_ label: String, for profile: SidebarProfile) -> String {
        elsewhere(profile) == nil ? label : Strings.spaceInAnotherWindow(label)
    }

    // MARK: Click

    func click(_ index: Int, option: Bool) {
        let profile = model.profiles[index]
        let outcome = SpaceSwitcherLogic.click(profile.id, active: model.activeProfileID, elsewhere: elsewhere(profile),
                                               hereIsIncognito: model.windowIsIncognito, style: switcherStyle, option: option)
        switch outcome {
        case .none: return
        case .switchHere: model.send(.switchProfile(profile.id))
        case .goToWindow: model.send(.goToSpaceWindow(profile.id))
        case .offer(let choices): showMenu(choiceMenu(profile.id, choices), at: index)
        case .spaceMenu: showMenu(spaceMenu(), at: index)
        }
    }

    /// Go to Window / Move Here for one space.
    func choiceMenu(_ space: ProfileKey, _ choices: [SpaceWindowChoice]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in choices { menu.addItem(item(for: choice, space: space)) }
        return menu
    }

    /// Arc's space menu (the `menu` style's current space): every space with its window, the current one checked;
    /// one another window shows takes Go to Window / Move Here in a submenu; New Space and New Incognito Space last.
    func spaceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for profile in model.profiles {
            let elsewhere = elsewhere(profile)
            let current = profile.id == model.activeProfileID
            let title = elsewhere == nil || current ? profile.name : Strings.spaceInAnotherWindow(profile.name)
            let opensChoices = elsewhere != nil && !current
            let id = profile.id
            let row = opensChoices ? SwitcherMenuItem(title: title, handler: nil)
                : SwitcherMenuItem(title: title) { [weak self] in self?.model.send(.switchProfile(id)) }
            row.state = current ? NSControl.StateValue.on : NSControl.StateValue.off
            if let elsewhere, opensChoices {
                row.submenu = choiceMenu(profile.id, SpaceSwitcherLogic.choices(for: elsewhere, hereIsIncognito: model.windowIsIncognito))
            }
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(SwitcherMenuItem(title: Strings.newProfile) { [weak self] in self?.model.send(.newProfile) })
        menu.addItem(SwitcherMenuItem(title: Strings.newIncognitoSpace) { [weak self] in self?.model.send(.newIncognitoSpace) })
        return menu
    }

    private func item(for choice: SpaceWindowChoice, space: ProfileKey) -> SwitcherMenuItem {
        switch choice {
        case .goToWindow: SwitcherMenuItem(title: Strings.goToSpaceWindow) { [weak self] in self?.model.send(.goToSpaceWindow(space)) }
        case .moveHere: SwitcherMenuItem(title: Strings.moveSpaceHere) { [weak self] in self?.model.send(.bringSpaceHere(space)) }
        }
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
