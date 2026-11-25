import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import Testing

/// Native menus follow Text Size (David Beyer, Nov 20: one text size for the sidebar, menus and chat): a context
/// or pop-up menu cmux shows draws at the system menu size times the person's text scale, the menu bar keeps the
/// system's, and at the default size no menu is touched.
@MainActor @Suite struct MenuTextSizeTests {
    let base = NSFont.menuFont(ofSize: 0).pointSize

    final class Scale {
        var value: CGFloat
        init(_ value: CGFloat) { self.value = value }
    }

    func menu(_ title: String = "Rename") -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        return menu
    }

    @Test func aContextMenuDrawsAtTheTextScaleAndBackAtDefault() {
        let center = NotificationCenter()
        let scale = Scale(16.0 / 14.0)
        let sizer = MenuTextSize(tracking: MenuTracking(center: center), scale: { scale.value }, mainMenu: { nil })
        let context = menu()
        center.post(name: NSMenu.didBeginTrackingNotification, object: context)
        #expect(context.font.pointSize == MenuTextSize.size(base: base, scale: scale.value))
        #expect(context.font.pointSize > base)

        scale.value = 1
        center.post(name: NSMenu.didBeginTrackingNotification, object: context)
        #expect(context.font.pointSize == base)
        withExtendedLifetime(sizer) {}
    }

    @Test func theMenuBarKeepsTheSystemSize() {
        let center = NotificationCenter()
        let main = NSMenu(), file = menu("New Window")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        let sizer = MenuTextSize(tracking: MenuTracking(center: center), scale: { 1.3 }, mainMenu: { main })
        center.post(name: NSMenu.didBeginTrackingNotification, object: main)
        center.post(name: NSMenu.didBeginTrackingNotification, object: file)
        #expect(main.font.pointSize == base)
        #expect(file.font.pointSize == base)
        withExtendedLifetime(sizer) {}
    }

    @Test func atTheDefaultSizeAMenuWithItsOwnFontKeepsIt() {
        let center = NotificationCenter()
        let sizer = MenuTextSize(tracking: MenuTracking(center: center), scale: { 1 }, mainMenu: { nil })
        let small = menu()
        small.font = NSFont.menuFont(ofSize: 11)
        center.post(name: NSMenu.didBeginTrackingNotification, object: small)
        #expect(small.font.pointSize == 11)
        withExtendedLifetime(sizer) {}
    }
}
