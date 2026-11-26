import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeModel
import Testing

/// The inbox rules run in Rust (cmux-home-rules `inbox.*`, tests/inbox_parity.rs holds their cases); this asks a few
/// through the linked FFI from the Swift types, so a library without the ops fails here, not in the app.
@MainActor
struct HomeInboxRulesSmokeTests {
    @Test func theSwiftTypesReachTheInboxOps() {
        let main = ConversationID("conv_main")
        var pins = HomePins()
        #expect(pins.leading(main) == main, "the main Chief leads until the person places it")
        pins.place(main, at: 1, shown: [ConversationID("conv_a"), main, ConversationID("conv_b")])
        #expect(pins.pinned == [ConversationID("conv_a"), main, ConversationID("conv_b")])
        #expect(pins.leading(main) == nil)
        #expect(HomeSidebarWidth.drag(-40, widest: 700) == 0)
        #expect(HomeSidebarWidth.clamp(250, window: 1400) == 250)
        #expect([InboxRow]().homeSections.isEmpty)
    }
}
