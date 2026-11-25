@testable import MessagesLabHome

extension HomeTableRowProvider {
    /// Fresh table and plan cards for a suite, each put in place in one step. Suites run in parallel and share the
    /// process's providers: an unregister-then-install left a moment with no table cards, in which another suite's
    /// mapping drew its tables as text (HomeStreamMapperTests failed at random, a1317 2026-11-21). No suite removes them.
    static func reinstall() {
        CustomRows.register(HomeTableRowProvider())
        CustomRows.register(HomePlanRowProvider())
    }
}
