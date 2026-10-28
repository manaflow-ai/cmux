import CoreGraphics
@testable import CmuxNextApp
import Testing

/// Restoring a window after the screens changed (pro-audits item 2, lid close): a frame saved on a large
/// external display comes back on the smaller built-in screen. It must fit that screen with its title bar
/// on it, or the person cannot move or resize the window.
struct WindowPlacementLidCloseTests {
    /// A 14-inch MacBook Pro's built-in screen at its default scale, below the menu bar.
    private static let builtIn = (id: String?("builtin"), visible: CGRect(x: 0, y: 0, width: 1512, height: 949))

    private static func inside(_ frame: CGRect, _ screen: CGRect) -> Bool {
        frame.minX >= screen.minX && frame.minY >= screen.minY && frame.maxX <= screen.maxX && frame.maxY <= screen.maxY
    }

    /// Clamshell: the external 2560x1440 display was the main one at the origin; with it gone, the saved
    /// full-size frame covers the built-in screen and its title bar is 491 pt above the screen's top.
    @Test func aFrameLargerThanItsScreenIsShrunkOntoIt() {
        let saved = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let placed = WindowPlacementFallback.place(saved, display: "external", screens: [Self.builtIn])
        #expect(Self.inside(placed, Self.builtIn.visible), "placed \(placed)")
        #expect(placed.width == 1512 && placed.height == 949)
    }

    /// The window fits but its top (the title bar) is above the screen: it moves down to the screen's top.
    @Test func aTitleBarAboveTheScreenComesBackOnIt() {
        let saved = CGRect(x: 100, y: 600, width: 800, height: 600)
        let placed = WindowPlacementFallback.place(saved, display: "builtin", screens: [Self.builtIn])
        #expect(placed.maxY <= Self.builtIn.visible.maxY, "placed \(placed)")
        #expect(placed.size == saved.size)
        #expect(placed.minX == saved.minX)
    }

    /// A frame that fits its screen keeps its place and size.
    @Test func aFrameThatFitsIsKept() {
        let saved = CGRect(x: 200, y: 100, width: 900, height: 700)
        #expect(WindowPlacementFallback.place(saved, display: "builtin", screens: [Self.builtIn]) == saved)
    }

    /// A window the person pushed partly off the side, title bar still on screen, keeps its place.
    @Test func aFramePartlyOffTheSideWithItsTitleBarOnScreenIsKept() {
        let saved = CGRect(x: 1200, y: 100, width: 800, height: 600)
        #expect(WindowPlacementFallback.place(saved, display: "builtin", screens: [Self.builtIn]) == saved)
    }

    /// Of two screens, the one that shows most of the frame decides; the frame fits there and is kept.
    @Test func theScreenShowingMostOfTheFrameDecides() {
        let external = (id: String?("external"), visible: CGRect(x: 1512, y: 0, width: 2560, height: 1415))
        let saved = CGRect(x: 1500, y: 100, width: 2000, height: 1200)
        let placed = WindowPlacementFallback.place(saved, display: "external", screens: [Self.builtIn, external])
        #expect(placed == saved)
    }

    /// A frame no screen shows is still centered on the main screen, at most its size (the old rule).
    @Test func aFrameNoScreenShowsIsCenteredOnTheMainScreen() {
        let saved = CGRect(x: 3000, y: 0, width: 2560, height: 1440)
        let placed = WindowPlacementFallback.place(saved, display: "external", screens: [Self.builtIn])
        #expect(placed == CGRect(x: 0, y: 0, width: 1512, height: 949))
    }
}
