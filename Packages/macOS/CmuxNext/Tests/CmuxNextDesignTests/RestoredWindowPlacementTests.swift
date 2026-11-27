import CoreGraphics
import CmuxNextDesign
import Testing

/// #25568: a restored window comes back where it was when its display is still connected, and
/// is moved onto a screen when its display is gone or it hangs off every screen
/// (`WindowPlacement.restoredFrame`). Screens are AppKit points, bottom-left origin, main first.
@MainActor @Suite struct RestoredWindowPlacementTests {
    /// A 1440x900 built-in display (menu bar 25 pt, no Dock) and a 1920x1080 display to its right.
    static let builtIn = (id: Optional("built-in"), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
    static let external = (id: Optional("external"), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

    @Test func aFrameOnItsConnectedDisplayComesBackExactly() {
        let frame = CGRect(x: 1600, y: 120, width: 1100, height: 720)
        #expect(WindowPlacement.restoredFrame(frame, display: "external", screens: [Self.builtIn, Self.external]) == frame)
    }

    @Test func aFrameSpanningTwoConnectedDisplaysStaysWhereItWas() {
        let frame = CGRect(x: 1000, y: 100, width: 1100, height: 700)
        #expect(WindowPlacement.restoredFrame(frame, display: "built-in", screens: [Self.builtIn, Self.external]) == frame)
    }

    @Test func aRecordWithNoDisplayKeepsAGrabbableFrame() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowPlacement.restoredFrame(frame, display: nil, screens: [Self.builtIn]) == frame)
    }

    /// The external display was unplugged: its window lands on the built-in one, whole.
    @Test func aWindowWhoseDisplayIsGoneMovesWhollyOntoAConnectedScreen() {
        // Mostly on the old external display, its left 200 pt over the built-in one.
        let frame = CGRect(x: 1240, y: 100, width: 1100, height: 700)
        let placed = WindowPlacement.restoredFrame(frame, display: "external", screens: [Self.builtIn])
        #expect(placed == CGRect(x: 340, y: 100, width: 1100, height: 700))
        #expect(Self.builtIn.visible.contains(placed))
    }

    @Test func aWindowWhoseDisplayIsGoneAndNoScreenShowsIsCenteredOnTheMainScreen() {
        let frame = CGRect(x: 2000, y: 100, width: 1100, height: 700)
        let placed = WindowPlacement.restoredFrame(frame, display: "external", screens: [Self.builtIn])
        #expect(placed == CGRect(x: 170, y: 87.5, width: 1100, height: 700))
    }

    /// A window saved larger than the screen it comes back on is shrunk to fit.
    @Test func aWindowLargerThanTheScreenItLandsOnIsShrunkToFit() {
        let frame = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let placed = WindowPlacement.restoredFrame(frame, display: "external", screens: [Self.builtIn])
        #expect(placed == Self.builtIn.visible)
    }

    /// Its display is connected, but its title bar is above the top of every screen: it moves
    /// down until the title bar shows.
    @Test func aWindowWhoseTitleBarIsOffScreenMovesBackOn() {
        let frame = CGRect(x: 200, y: 400, width: 800, height: 600)
        let placed = WindowPlacement.restoredFrame(frame, display: "built-in", screens: [Self.builtIn])
        #expect(placed == CGRect(x: 200, y: 275, width: 800, height: 600))
        #expect(WindowPlacement.canGrabTitleBar(of: placed, on: Self.builtIn.visible))
    }

    /// Only a 30 pt sliver of it shows, at a screen's edge (too little to grab): it is moved wholly onto that screen.
    @Test func aWindowWithOnlyASliverOnScreenMovesWhollyOn() {
        let frame = CGRect(x: -770, y: 100, width: 800, height: 600)
        let placed = WindowPlacement.restoredFrame(frame, display: "built-in", screens: [Self.builtIn])
        #expect(placed == CGRect(x: 0, y: 100, width: 800, height: 600))
    }

    @Test func aWindowOffEveryScreenIsCenteredOnItsSavedDisplay() {
        let frame = CGRect(x: -5000, y: 3000, width: 800, height: 600)
        let placed = WindowPlacement.restoredFrame(frame, display: "external", screens: [Self.builtIn, Self.external])
        #expect(placed == CGRect(x: 2000, y: 227.5, width: 800, height: 600))
    }

    @Test func withNoScreenTheFrameIsKept() {
        let frame = CGRect(x: -5000, y: 3000, width: 800, height: 600)
        #expect(WindowPlacement.restoredFrame(frame, display: "external", screens: []) == frame)
    }
}
