import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct AppKitContextMenuTests {
    /// Items and separators map to `NSMenuItem`s in order, honoring `isEnabled`.
    @Test func buildsItemsAndSeparatorsInOrder() {
        let menu = CmuxContextMenu(from: [
            .button("First") {},
            .separator,
            .button("Disabled", isEnabled: false) {},
        ])

        #expect(menu.items.count == 3)
        #expect(menu.items[0].title == "First")
        #expect(menu.items[0].isEnabled == true)
        #expect(menu.items[1].isSeparatorItem == true)
        #expect(menu.items[2].title == "Disabled")
        #expect(menu.items[2].isEnabled == false)
    }

    /// `autoenablesItems` is off so explicit `isEnabled` is authoritative.
    @Test func disablesAutoEnable() {
        let menu = CmuxContextMenu(from: [.button("Only") {}])
        #expect(menu.autoenablesItems == false)
    }

    /// A `systemImage` produces an item image; omitting it leaves the image nil.
    @Test func setsImageOnlyWhenSystemImageProvided() {
        let menu = CmuxContextMenu(from: [
            .button("With Icon", systemImage: "trash") {},
            .button("No Icon") {},
        ])

        #expect(menu.items[0].image != nil)
        #expect(menu.items[1].image == nil)
    }

    /// Enabled items wire their action to a retained target that runs the closure.
    @Test func invokingTargetRunsAction() {
        var ran = 0
        let menu = CmuxContextMenu(from: [.button("Run") { ran += 1 }])

        let item = menu.items[0]
        let target = item.target as? CmuxContextMenuActionTarget
        #expect(target != nil)
        #expect(item.action == #selector(CmuxContextMenuActionTarget.invoke(_:)))

        target?.invoke(nil)
        #expect(ran == 1)
    }

    /// Disabled items carry no action target (nothing to invoke).
    @Test func disabledItemHasNoTarget() {
        let menu = CmuxContextMenu(from: [.button("Off", isEnabled: false) {}])
        #expect(menu.items[0].target == nil)
        #expect(menu.items[0].action == nil)
    }

    /// Leading separators are dropped (an entry that only has a trailing group).
    @Test func dropsLeadingSeparator() {
        let menu = CmuxContextMenu(from: [.separator, .button("Only") {}])
        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == "Only")
    }

    /// Trailing separators are dropped (an entry whose only group leads the menu).
    @Test func dropsTrailingSeparator() {
        let menu = CmuxContextMenu(from: [.button("Only") {}, .separator])
        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == "Only")
    }

    /// Consecutive separators collapse to a single divider, matching SwiftUI.
    @Test func collapsesConsecutiveSeparators() {
        let menu = CmuxContextMenu(from: [
            .button("A") {},
            .separator,
            .separator,
            .button("B") {},
        ])
        #expect(menu.items.count == 3)
        #expect(menu.items[0].title == "A")
        #expect(menu.items[1].isSeparatorItem == true)
        #expect(menu.items[2].title == "B")
    }

    /// An empty element list builds an empty menu (capture view treats this as a no-op).
    @Test func emptyElementsBuildEmptyMenu() {
        let menu = CmuxContextMenu(from: [])
        #expect(menu.items.isEmpty)
    }

    /// All-separator input builds an empty menu (every separator is degenerate).
    @Test func allSeparatorsBuildEmptyMenu() {
        let menu = CmuxContextMenu(from: [.separator, .separator])
        #expect(menu.items.isEmpty)
    }

    /// The capture view tolerates a nil/empty provider without presenting a menu.
    @Test func captureViewWithoutElementsDoesNotCrash() {
        let view = AppKitContextMenuCaptureView()
        view.elementsProvider = { [] }

        if let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            view.rightMouseDown(with: event)
        }
        // No menu should be presented; reaching here without a crash is the assertion.
        #expect(view.elementsProvider != nil)
    }
}
