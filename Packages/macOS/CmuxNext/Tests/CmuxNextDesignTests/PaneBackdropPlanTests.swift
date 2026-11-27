@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// What one pane draws for its background (plans/cmux-next/pane-backgrounds-DESIGN.md): the
/// shared window art, its own copy, its own pick, a plain cover, and the marker tint.
struct PaneBackdropPlanTests {
    private let art = BackdropSelection.system(path: "/System/Library/Desktop Pictures/Sequoia.heic")

    /// A see-through window backdrop over `selection` (translucent at 0.7).
    private func backdrop(_ selection: BackdropSelection?, reduceTransparency: Bool = false) -> WindowBackdrop {
        var backdrop = WindowBackdrop(backgroundOpacity: selection == nil ? 1 : 0.7, backgroundBlur: 0,
                                      reduceTransparency: reduceTransparency, liquidGlass: false)
        backdrop.selection = selection
        return backdrop
    }

    @Test func sharedModeWithoutOwnBackgroundDrawsNothing() {
        let plan = PaneBackdropPlan.resolve(mode: .shared, own: .inherit, tint: nil, backdrop: backdrop(art), inheritedHasArt: true)
        #expect(plan == .none)
        #expect(!plan.needsView)
    }

    @Test func perPaneModeDrawsItsOwnCopyOfTheSharedArt() throws {
        let plan = PaneBackdropPlan.resolve(mode: .perPane, own: .inherit, tint: nil, backdrop: backdrop(art), inheritedHasArt: true)
        let drawn = try #require(plan.art)
        #expect(drawn.selection == art)
        // Only art and tint per pane: never a Liquid Glass view per pane.
        #expect(drawn.material == .translucent)
        #expect(drawn.tintOpacity == backdrop(art).tintOpacity)
        #expect(!plan.cover)
    }

    @Test func ownPickDrawsInSharedModeToo() throws {
        let plan = PaneBackdropPlan.resolve(mode: .shared, own: .selection(art), tint: nil, backdrop: backdrop(art), inheritedHasArt: false)
        #expect(try #require(plan.art).selection == art)
    }

    @Test func ownNoneCoversInheritedArtWithThePlainBackground() {
        let plan = PaneBackdropPlan.resolve(mode: .shared, own: .none, tint: nil, backdrop: backdrop(nil), inheritedHasArt: true)
        #expect(plan.art == nil)
        #expect(plan.cover)
    }

    @Test func ownNoneWithoutInheritedArtNeedsNoCover() {
        let plan = PaneBackdropPlan.resolve(mode: .perPane, own: .none, tint: nil, backdrop: backdrop(nil), inheritedHasArt: false)
        #expect(plan == .none)
    }

    @Test func reduceTransparencyDrawsNoArtButKeepsTheMarkerTint() throws {
        let red = try #require(PaneTint("red"))
        let plan = PaneBackdropPlan.resolve(mode: .perPane, own: .selection(art), tint: red,
                                            backdrop: backdrop(art, reduceTransparency: true), inheritedHasArt: true)
        #expect(plan.art == nil)
        #expect(plan.tint == red)
        #expect(plan.needsView)
    }

    @Test func tintAloneIsAMarkerInAnOpaqueWindow() throws {
        let blue = try #require(PaneTint("#3366FF"))
        let plan = PaneBackdropPlan.resolve(mode: .shared, own: .inherit, tint: blue, backdrop: backdrop(nil), inheritedHasArt: false)
        #expect(plan.art == nil)
        #expect(plan.tint == blue)
        #expect(plan.tintAlpha == PaneBackdropPlan.markerTintAlpha)
    }

    @Test(arguments: ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "gray"])
    func namedTintsParseAndRoundTrip(_ name: String) throws {
        let tint = try #require(PaneTint(name))
        #expect(tint.id == name)
        #expect(PaneTint(tint.id) == tint)
    }

    @Test func hexTintsNormalizeAndBadValuesFail() throws {
        let tint = try #require(PaneTint("#ff8800"))
        #expect(tint.id == "#FF8800")
        #expect(tint.red == 1 && tint.blue == 0)
        #expect(PaneTint("#12345") == nil)
        #expect(PaneTint("magenta-ish") == nil)
        #expect(PaneTint("none") == nil)
    }

    @Test func modeParsesItsRawValues() {
        #expect(PaneBackgroundMode(rawValue: "shared") == .shared)
        #expect(PaneBackgroundMode(rawValue: "perPane") == .perPane)
        #expect(PaneBackgroundMode.allCases.count == 2)
    }
}
