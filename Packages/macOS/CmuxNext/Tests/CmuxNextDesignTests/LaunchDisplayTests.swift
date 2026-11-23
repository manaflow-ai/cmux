import CoreGraphics
import CmuxNextDesign
import Testing

/// #51115: a tagged dev build opens its shell windows on the Mac's built-in display, never on
/// the external display beside it (`LaunchDisplay`). Screens are AppKit points, bottom-left
/// origin, in `NSScreen.screens` order: here an external display holds the menu bar.
@Suite struct LaunchDisplayTests {
    /// A 3008x1667 external display (menu bar 25 pt) and a 1512x957 built-in one to its left.
    static let external = (isBuiltIn: false, visible: CGRect(x: 0, y: 0, width: 3008, height: 1667))
    static let builtIn = (isBuiltIn: true, visible: CGRect(x: -1512, y: 0, width: 1512, height: 957))
    static let screens = [external, builtIn]
    static let size = CGSize(width: 1100, height: 720)

    @Test func aTaggedDevBuildDefaultsToTheBuiltInDisplay() {
        #expect(LaunchDisplay.parse(nil, isDevBuild: true) == .builtIn)
        #expect(LaunchDisplay.parse("  ", isDevBuild: true) == .builtIn)
        #expect(LaunchDisplay.parse("BuiltIn", isDevBuild: true) == .builtIn)
    }

    @Test func nightlyAndStableKeepTheUsualPlacementUnlessAsked() {
        #expect(LaunchDisplay.parse(nil, isDevBuild: false) == nil)
        #expect(LaunchDisplay.parse("builtin", isDevBuild: false) == .builtIn)
    }

    @Test func theEnvironmentOverridesTheDefault() {
        #expect(LaunchDisplay.parse("off", isDevBuild: true) == nil)
        #expect(LaunchDisplay.parse("main", isDevBuild: true) == .index(0))
        #expect(LaunchDisplay.parse("1", isDevBuild: true) == .index(1))
        #expect(LaunchDisplay.parse("-1", isDevBuild: true) == nil)
        #expect(LaunchDisplay.parse("xdr", isDevBuild: true) == nil)
    }

    @Test func aNewWindowOpensCenteredOnTheBuiltInDisplayNotTheMenuBarOne() {
        let placed = LaunchDisplay.builtIn.frame(nil, defaultSize: Self.size, screens: Self.screens)
        #expect(placed == CGRect(x: -1306, y: 119, width: 1100, height: 720))
        #expect(placed.map { Self.builtIn.visible.contains($0) } == true)
    }

    @Test func aWindowSavedOnTheExternalDisplayMovesToTheBuiltInOneKeepingItsSize() {
        let saved = CGRect(x: 400, y: 300, width: 1400, height: 900)
        let placed = LaunchDisplay.builtIn.frame(saved, defaultSize: Self.size, screens: Self.screens)
        #expect(placed == CGRect(x: -1456, y: 29, width: 1400, height: 900))
    }

    @Test func aWindowAlreadyOnTheBuiltInDisplayStaysWhereItIs() {
        let saved = CGRect(x: -1400, y: 100, width: 900, height: 600)
        #expect(LaunchDisplay.builtIn.frame(saved, defaultSize: Self.size, screens: Self.screens) == saved)
    }

    @Test func aWindowHangingOffTheBuiltInDisplayIsPulledWhollyOntoIt() {
        let saved = CGRect(x: -800, y: 100, width: 1100, height: 700)
        #expect(LaunchDisplay.builtIn.frame(saved, defaultSize: Self.size, screens: Self.screens) == CGRect(x: -1100, y: 100, width: 1100, height: 700))
    }

    @Test func furtherWindowsCascadeSoEachStaysVisible() {
        let second = LaunchDisplay.builtIn.frame(nil, defaultSize: Self.size, cascade: 1, screens: Self.screens)
        #expect(second == CGRect(x: -1282, y: 95, width: 1100, height: 720))
    }

    @Test func aMacWithoutABuiltInDisplayKeepsTheUsualPlacement() {
        #expect(LaunchDisplay.builtIn.frame(nil, defaultSize: Self.size, screens: [Self.external]) == nil)
        #expect(LaunchDisplay.builtIn.frame(nil, defaultSize: Self.size, screens: []) == nil)
    }

    /// An onboarding or other auxiliary window with no parent (the app is not active) opens on
    /// the launch display, not on `NSScreen.main`, which is then the person's display.
    @Test func aParentlessAuxiliaryWindowOpensOnTheLaunchDisplay() {
        #expect(WindowPlacement.ownerScreen(parent: nil, launch: 1, main: 0) == 1)
        #expect(WindowPlacement.ownerScreen(parent: 0, launch: 1, main: 0) == 0)
        #expect(WindowPlacement.ownerScreen(parent: nil, launch: nil, main: 2) == 2)
        #expect(WindowPlacement.ownerScreen(parent: nil, launch: nil, main: nil) == 0)
    }

    @Test func anIndexPicksThatScreenAndOnePastTheEndPicksTheLast() {
        #expect(LaunchDisplay.index(0).screenIndex(builtIn: [false, true]) == 0)
        #expect(LaunchDisplay.index(5).screenIndex(builtIn: [false, true]) == 1)
    }
}
