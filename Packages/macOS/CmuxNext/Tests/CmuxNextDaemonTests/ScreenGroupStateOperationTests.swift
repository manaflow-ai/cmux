import Testing
@testable import CmuxNextDaemon

/// The v2 screen group operations carry cmux-tui's wire names and params
/// (`resource_router/state.rs`), so a retried request replays by its key.
@Suite struct ScreenGroupStateOperationTests {
    @Test func operationsUseTheDaemonsWireNamesAndParams() {
        typealias Op = ScreenGroupStateClient.Operation
        let create = Op.create(screens: ["scr_a", "scr_b"], name: "Agents", color: "green")
        #expect(create.name == "screen_group.create")
        #expect(create.params == ["screens": .array([.string("scr_a"), .string("scr_b")]), "name": .string("Agents"), "color": .string("green")])
        #expect(Op.addScreens(group: "sgrp_1", screens: ["scr_c"]).params == ["screen_group": .string("sgrp_1"), "screens": .array([.string("scr_c")])])
        #expect(Op.removeScreens(["scr_c"]).name == "screen_group.remove_screens")
        let collapse = Op.update(group: "sgrp_1", name: nil, color: nil, collapsed: true)
        #expect(collapse.name == "screen_group.update")
        #expect(collapse.params == ["screen_group": .string("sgrp_1"), "collapsed": .bool(true)], "only the fields that change")
        #expect(Op.ungroup(group: "sgrp_1").params == ["screen_group": .string("sgrp_1")])
    }
}
