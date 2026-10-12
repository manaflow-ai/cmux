@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTabs
import Testing

/// New tab groups and screen groups get their colors the way workspace groups do (cx-wqn5): the
/// terminal palette in the theme's order, never grey or blue, so the first group of a strip
/// already has a color and every kind of group walks the same sequence.
@MainActor
struct GroupColorDefaultsTests {
    @Test func tabAndScreenGroupsWalkTheThemeOrder() {
        #expect(ScreenGroupCommands.nextColor(in: nil) == GroupColor.automaticOrder[0])
        var used: [GroupColor] = []
        for expected in GroupColor.automaticOrder {
            let next = TabGroupOrdering.nextColor(used: used)
            #expect(next == expected)
            #expect(next == GroupColor.automatic(used: Set(used.map(\.rawValue))))
            used.append(next)
        }
        // Every theme color taken: grey (none), as before.
        #expect(TabGroupOrdering.nextColor(used: used) == .grey)
    }
}
