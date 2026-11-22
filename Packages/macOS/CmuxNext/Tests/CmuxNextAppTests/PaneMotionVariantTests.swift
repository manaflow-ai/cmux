import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The Debug choice `motion.pane.variant` and the spring tokens it names. No layout change reads them now (a split,
/// a close, a zoom and an unzoom are one commit and spring nothing); the choice and its tokens stay registered until
/// their own removal, so its store rules and the pairing of its tokens hold until then.
@MainActor
@Suite
struct PaneMotionVariantTests {
    /// The standard variant names the tokens of the motion pairs, so what `MotionCapTests` proves for a
    /// pair (its exit ends sooner than its enter, at every speed) holds for the variant's springs.
    @Test func theStandardVariantRunsTheTokensOfTheMotionPairs() {
        let standard = PaneMotionVariant.standard
        #expect(MotionPair.pane.enter == .spring(standard.splitSpring), "a split does not name the enter of the pane pair")
        #expect(MotionPair.pane.exit == .spring(standard.closeSpring), "a close does not name the exit of the pane pair")
        #expect(MotionPair.zoom.enter == .spring(standard.expandSpring), "a zoom does not name the enter of the zoom pair")
        #expect(MotionPair.zoom.exit == .spring(standard.restoreSpring), "an unzoom does not name the exit of the zoom pair")
    }

    @Test func debugChoiceIsInertUntilItsStoreIsActivatedAndResetsToCurrent() {
        let store = TunableStore()
        let choice = LayoutTunables.paneMotionVariant
        store.register(LayoutTunables.all)
        store.set(choice.key, PaneMotionVariant.crisp.tunableValue)
        #expect(choice.value(in: store) == .standard)
        store.activate(file: nil)
        #expect(choice.value(in: store) == .crisp)
        store.reset([choice.key])
        #expect(choice.value(in: store) == .standard)
    }
}
