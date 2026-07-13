import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct NativeTitlebarBackdropCoordinatorTests {
    @Test func hidesAndRestoresBothTitlebarControlAccessories() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let leading = Self.accessory(
            identifier: NativeTitlebarBackdropCoordinator.leadingControlsIdentifier
        )
        let trailing = Self.accessory(
            identifier: NativeTitlebarBackdropCoordinator.trailingControlsIdentifier
        )
        let unrelated = Self.accessory(identifier: NSUserInterfaceItemIdentifier("cmux.unrelatedAccessory"))
        window.addTitlebarAccessoryViewController(leading)
        window.addTitlebarAccessoryViewController(trailing)
        window.addTitlebarAccessoryViewController(unrelated)

        let coordinator = NativeTitlebarBackdropCoordinator(fullscreenAuxiliaryWindows: { [] })
        coordinator.setTitlebarControlsHidden(true, in: window, isMinimalMode: false)

        #expect(leading.isHidden)
        #expect(leading.view.isHidden)
        #expect(trailing.isHidden)
        #expect(trailing.view.isHidden)
        #expect(!unrelated.isHidden)
        #expect(!unrelated.view.isHidden)

        coordinator.setTitlebarControlsHidden(false, in: window, isMinimalMode: false)

        #expect(!leading.isHidden)
        #expect(!leading.view.isHidden)
        #expect(!trailing.isHidden)
        #expect(!trailing.view.isHidden)
    }

    private static func accessory(
        identifier: NSUserInterfaceItemIdentifier
    ) -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = NSView()
        accessory.view.identifier = identifier
        return accessory
    }
}
