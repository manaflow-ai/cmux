import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-FOOTER-AND-SPACE-MENU amendments 2 and 3 (Lawrence 2026-10-07):
/// the sidebar's bottom-left is one control, the current profile's avatar
/// (its initial in a 16 pt circle) with a small chevron; a click opens the
/// profile menu. The gear is gone (Settings is in the menu). The space dots
/// sit in the same row right after the control, anchored leading, so adding
/// or removing a space moves no existing dot and not the control (Leo: no
/// reflow). The footer row takes no drag and drop for now.
@MainActor @Suite(.serialized) struct SidebarProfileControlTests {
    static let account = LayoutItemID("itm_account")
    static let avatar = SidebarAvatar(name: "Work", color: nil)
    static let profiles = [SidebarProfile(id: ProfileKey("default"), name: "Default"),
                           SidebarProfile(id: ProfileKey("p2"), name: "Two"),
                           SidebarProfile(id: ProfileKey("p3"), name: "Three")]

    private func sidebar(profiles: Int = 2, intents: ((SidebarIntent) -> Void)? = nil) -> SidebarView {
        let model = SidebarModel()
        model.onIntent = intents
        model.profiles = Array(Self.profiles.prefix(profiles))
        model.activeProfileID = ProfileKey("default")
        var info = SidebarBuiltIn.account.defaultInfo
        info.avatar = Self.avatar
        info.title = Self.avatar.name
        model.itemInfo = [Self.account: info]
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func control(_ view: SidebarView) throws -> SidebarItemRowView {
        try #require(view.footerRegion.itemView(Self.account))
    }

    @Test func theFooterIsOneAvatarControlWithAChevronAndNoGear() throws {
        let view = sidebar()
        let control = try control(view)
        #expect(control.showsAvatar)
        #expect(!control.avatarView.isHidden)
        #expect(view.footerRegion.itemView(LayoutItemID("itm_settings")) == nil, "no gear")
        #expect(control.frame.height == Metrics.sidebarRowHeight)
        #expect(control.frame.width == SidebarStyle.avatarControlWidth)
        let circle = control.avatarView.circleFrame, chevron = control.avatarView.chevronFrame
        #expect(circle.width == 16 && circle.height == 16, "16 pt avatar at the default density: \(circle)")
        #expect(chevron.minX > circle.maxX && chevron.maxX <= control.bounds.maxX, "the chevron trails the circle inside the control")
        // The circle sits on the rows' glyph column and the row's center line.
        let inSidebar = view.convert(control.avatarView.convert(circle, to: view.footerRegion), from: view.footerRegion)
        let column = SidebarStyle.horizontalInset * 2 + SidebarStyle.iconBox / 2
        #expect(abs(inSidebar.midX - column) <= 0.5, "\(inSidebar.midX) vs \(column)")
        #expect(abs(inSidebar.midY - view.convert(control.frame, from: view.footerRegion).midY) <= 0.5)
        #expect(control.avatarView.avatar?.initial == "W")
        #expect(control.accessibilityRole() == .menuButton)
        #expect(control.accessibilityLabel() == "Work")
    }

    /// A click opens the App's profile menu over the control; it sends no
    /// item activation. The `sidebar.profileMenu` action path
    /// (`showProfileMenu()`) opens the same menu over the same control.
    @Test func aClickOpensTheProfileMenuOverTheControl() throws {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        let menu = NSMenu(title: "profile")
        var shown: [(NSMenu, NSView?)] = []
        view.profileMenuProvider = { menu }
        view.profileMenuPresenter = { shown.append(($0, $1)) }
        let control = try control(view)
        #expect(control.accessibilityPerformPress())
        #expect(shown.count == 1 && shown.first?.0 === menu && shown.first?.1 === control)
        #expect(intents.isEmpty, "no activateItem: \(intents)")
        #expect(view.showProfileMenu())
        #expect(shown.count == 2 && shown.last?.1 === control)
    }

    /// The dots share the control's row, right after it, and the dots row
    /// above the band is gone.
    @Test func theDotsSitInTheControlsRowAfterIt() throws {
        let view = sidebar()
        let control = view.convert(try control(view).frame, from: view.footerRegion)
        let bar = view.convert(view.profileBar.frame, from: view.profileBar.superview)
        #expect(abs(bar.midY - control.midY) <= 0.5, "one row: \(bar) \(control)")
        #expect(bar.minX >= control.maxX - 0.5, "after the control: \(bar) \(control)")
        #expect(view.footer.frame.height == 0, "no separate dots row")
    }

    /// Adding a space moves no existing dot, not the control and not the
    /// bar (Leo: no reflow); removing one does not either.
    @Test func addingOrRemovingASpaceMovesNothingElse() throws {
        let view = sidebar(profiles: 2)
        let controlFrame = view.convert(try control(view).frame, from: view.footerRegion)
        let barFrame = view.convert(view.profileBar.frame, from: view.profileBar.superview)
        let slot = Double(Metrics.roomDotSlot), leading = Double(view.profileBar.slotsLeading)
        let two = ProfileBarLogic.slotXs(count: 2, slot: slot, leading: leading)
        view.model.profiles = Self.profiles
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let three = ProfileBarLogic.slotXs(count: 3, slot: slot, leading: Double(view.profileBar.slotsLeading))
        #expect(Array(three.prefix(2)) == Array(two.prefix(2)), "existing dots stay: \(two) \(three)")
        #expect(view.convert(try control(view).frame, from: view.footerRegion) == controlFrame)
        #expect(view.convert(view.profileBar.frame, from: view.profileBar.superview) == barFrame)
        view.model.profiles = Array(Self.profiles.prefix(2))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.convert(view.profileBar.frame, from: view.profileBar.superview) == barFrame)
    }

    /// No drag and drop in the footer row for now (amendment 3): dragging
    /// the control starts no reorder, and dragging a dot onto another sends
    /// no reorder (and switches nothing).
    @Test func aDragInTheFooterRowDoesNothing() throws {
        var intents: [SidebarIntent] = []
        let view = sidebar(profiles: 3) { intents.append($0) }
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let control = try control(view)
        let start = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let far = NSPoint(x: start.x + 80, y: start.y + 40)
        let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: far, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(view.footerRegion.dragMoved(.item(Self.account), from: start, drag) == false)
        #expect(view.footerRegion.reorder == nil)

        let bar = view.profileBar
        let slot = Metrics.roomDotSlot
        func event(_ type: NSEvent.EventType, slotIndex: Int) throws -> NSEvent {
            let x = bar.slotsLeading + slot * (CGFloat(slotIndex) + 0.5)
            let point = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        bar.mouseDown(with: try event(.leftMouseDown, slotIndex: 0))
        bar.mouseDragged(with: try event(.leftMouseDragged, slotIndex: 2))
        bar.mouseUp(with: try event(.leftMouseUp, slotIndex: 2))
        #expect(!intents.contains { if case .reorderProfile = $0 { true } else { false } }, "\(intents)")
        #expect(intents.isEmpty, "a press that ends on another dot does nothing: \(intents)")
    }

    /// SIDEBAR-FOOTER-MINIMAL's untouched footer (avatar, then gear) loses
    /// the gear through an ordinary op; a footer the user changed is kept.
    @Test func theMinimalFooterLosesTheGear() throws {
        var stored = SidebarLayoutDocument.defaults
        let bottom = try #require(stored.sections.firstIndex { $0.id == SidebarLayoutDocument.bottomSectionID })
        stored.sections[bottom] = SidebarLayoutDocument.minimalBottomSection
        #expect(stored.sectionsMigrationOps == [.itemRemove(LayoutItemID("itm_settings"))])
        #expect(stored.layoutMigration.section(SidebarLayoutDocument.bottomSectionID) == SidebarLayoutDocument.defaults.section(SidebarLayoutDocument.bottomSectionID))
        let custom = try SidebarLayoutReducer.reduce(stored, .itemUpdate(LayoutItemID("itm_settings"), showsLabel: true)).get()
        #expect(custom.sectionsMigrationOps.isEmpty)
    }
}
