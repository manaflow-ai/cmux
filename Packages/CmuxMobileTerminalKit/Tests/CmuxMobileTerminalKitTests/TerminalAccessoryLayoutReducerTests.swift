import Foundation
import Testing

@testable import CmuxMobileTerminalKit

@Suite("TerminalAccessoryLayoutReducer")
struct TerminalAccessoryLayoutReducerTests {
    private let reducer = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3])

    @Test("first launch shows everything in canonical order")
    func firstLaunch() {
        let layout = reducer.load(savedOrder: [], savedEnabled: nil)
        #expect(layout.order == [0, 1, 2, 3])
        #expect(layout.enabled == Set([0, 1, 2, 3]))
        #expect(layout.visibleOrder == [0, 1, 2, 3])
    }

    @Test("saved order is honored, then missing actions append (forward-compat)")
    func savedOrderForwardCompat() {
        let layout = reducer.load(savedOrder: [2, 0], savedEnabled: [2, 0])
        #expect(layout.order == [2, 0, 1, 3])
        #expect(layout.visibleOrder == [2, 0])
    }

    @Test("unknown identifiers are dropped from saved order and enabled")
    func dropsUnknown() {
        let layout = reducer.load(savedOrder: [99, 1, 0], savedEnabled: [99, 1])
        #expect(layout.order == [1, 0, 2, 3])
        #expect(layout.enabled == Set([1]))
    }

    @Test("empty saved enabled means user hid everything, not first launch")
    func emptyEnabledIsHonored() {
        let layout = reducer.load(savedOrder: [0, 1, 2, 3], savedEnabled: [])
        #expect(layout.enabled.isEmpty)
        #expect(layout.visibleOrder.isEmpty)
    }

    @Test("setEnabled toggles visibility and ignores unknown identifiers")
    func setEnabled() {
        var layout = reducer.defaultLayout()
        layout = reducer.setEnabled(1, false, in: layout)
        #expect(layout.visibleOrder == [0, 2, 3])
        layout = reducer.setEnabled(1, true, in: layout)
        #expect(layout.visibleOrder == [0, 1, 2, 3])
        let unchanged = reducer.setEnabled(99, false, in: layout)
        #expect(unchanged == layout)
    }

    @Test("move reorders within the configurable region")
    func move() {
        var layout = reducer.defaultLayout()
        layout = reducer.move(from: IndexSet(integer: 0), to: 4, in: layout)
        #expect(layout.order == [1, 2, 3, 0])
        #expect(layout.enabled == Set([0, 1, 2, 3]))
    }

    @Test("defaultLayout is canonical order, all enabled")
    func defaultLayout() {
        let layout = reducer.defaultLayout()
        #expect(layout.order == [0, 1, 2, 3])
        #expect(layout.enabled == Set([0, 1, 2, 3]))
    }
}
