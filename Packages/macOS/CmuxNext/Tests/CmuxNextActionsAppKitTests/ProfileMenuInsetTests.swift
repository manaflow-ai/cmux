import AppKit
@testable import CmuxNextActions
@testable import CmuxNextActionsAppKit
import Testing

/// The sidebar profile menu's rows sit at the plain menu inset (Leo 2026-10-13, cosmic-gray on
/// macOS 27): the current profile's checkmark reserved a state column and its avatar an image
/// column, and every row of the menu sat right of both.
@MainActor
struct ProfileMenuInsetTests {
    /// The same rows with no state and no image on any of them, submenus included.
    private func plain(_ menu: NSMenu) -> NSMenu {
        let copy = menu.copy() as! NSMenu
        func strip(_ menu: NSMenu) {
            for item in menu.items {
                item.state = .off
                item.image = nil
                item.submenu.map(strip)
            }
        }
        strip(copy)
        return copy
    }

    @Test func theProfileMenuReservesNoColumnBeyondThePlainInset() {
        let menu = ProfileMenuBuilder(registry: .standard()).make(profile: ProfileMenuProfile(name: "Default"))
        #expect(menu.size.width == plain(menu).size.width)
    }
}
