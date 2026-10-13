import AppKit
@testable import CmuxNextActions
import Testing

/// The sidebar profile menu's rows sit at the plain menu inset (Leo 2026-10-13, cosmic-gray on
/// macOS 27): a checkmark on the current profile reserved a state column, which pushed every row
/// right by that column. With one profile the checkmark meant nothing.
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
        let menu = ProfileMenuBuilder(registry: .standard()).make(profile: ProfileMenuProfile(name: "Default", initial: "D"))
        #expect(menu.size.width == plain(menu).size.width)
    }
}
