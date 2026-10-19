import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// The Home conversation list draws no system blue (the user, 2026-10-18: "dont use blue here"):
/// a selected pinned tile or row takes the neutral unemphasized grey in every window state, as
/// Messages' pinned grid, and the compose and filter buttons are the same round button.
@MainActor
struct HomeSidebarNeutralSelectionTests {
    @Test(arguments: [NSAppearance.Name.darkAqua, .aqua])
    func theSelectionIsNeutralGreyNotBlue(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        home.appearance = appearance
        let controller = home.list.controller
        controller.appearanceChanged()
        var blue: CGColor?, grey: CGColor?, label: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            blue = NSColor.selectedContentBackgroundColor.cgColor
            grey = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            label = NSColor.labelColor.cgColor
        }
        let p = controller.palette
        #expect(!Self.same(p.selectionActive, blue), "the key-window selection is the system blue")
        #expect(Self.same(p.selectionActive, grey), "the key-window selection is not the neutral grey")
        #expect(Self.same(p.selectedText, label), "the selected text is not the label colour")
        // Home focused or not (the window not key): the same grey, never blue.
        controller.setWindowActive(false)
        #expect(Self.same(controller.palette.selectionInactive, grey))
        #expect(!Self.same(controller.palette.selectionInactive, blue))
        #expect(Self.same(controller.palette.selectionActive, controller.palette.selectionInactive))
    }

    @Test func composeAndFilterAreTheSameRoundButton() throws {
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        home.layoutSubtreeIfNeeded()
        let filter = home.list.controller.filterButton
        #expect(home.compose.frame.width == home.compose.frame.height)
        #expect(filter.frame.size == home.compose.frame.size)
        for button in [home.compose, filter] {
            let layer = try #require(button.layer)
            #expect(layer.cornerRadius == button.frame.height / 2)
            #expect(layer.backgroundColor != nil)
        }
    }

    /// Equal after conversion to sRGB (system colours resolve in different colour spaces).
    private static func same(_ a: CGColor?, _ b: CGColor?) -> Bool {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let x = a?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              let y = b?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              x.count == y.count else { return false }
        return zip(x, y).allSatisfy { abs($0 - $1) < 0.002 }
    }
}
