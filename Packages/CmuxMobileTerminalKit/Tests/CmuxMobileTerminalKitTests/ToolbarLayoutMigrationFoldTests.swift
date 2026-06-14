import Testing

@testable import CmuxMobileTerminalKit

@Suite("ToolbarLayoutMigration newly-configurable fold")
struct ToolbarLayoutMigrationFoldTests {
    private let migration = ToolbarLayoutMigration()
    // Mirrors the real action rawValues used as anchors: control=0, alternate=1,
    // command=2; the newly-configurable id under test is shift=3.
    private let shift = ToolbarItemID.builtin(3)
    private let anchors = [2, 1, 0].map { ToolbarItemID.builtin($0) } // command, then alternate, then control

    @Test("a v3 layout missing the id gains it right after the first anchor, force-shown")
    func foldsInAfterAnchorAndEnables() throws {
        // control(0) alternate(1) command(2) paste(27) tab(7), shift absent.
        let order = [0, 1, 2, 27, 7].map { ToolbarItemID.builtin($0) }
        let widened = try #require(migration.foldingNewlyConfigurable(
            shift, after: anchors, order: order, enabled: order
        ))
        // shift lands immediately after command(2), ahead of paste(27) and tab(7).
        #expect(widened.order == [
            .builtin(0), .builtin(1), .builtin(2), .builtin(3), .builtin(27), .builtin(7),
        ])
        #expect(widened.enabled.contains(shift))
    }

    @Test("a layout already containing the id is left untouched (returns nil)")
    func noOpWhenAlreadyPresent() {
        let order = [0, 1, 2, 3].map { ToolbarItemID.builtin($0) }
        // Even when the id is present-but-hidden, the user's choice is authoritative.
        #expect(migration.foldingNewlyConfigurable(
            shift, after: anchors, order: order, enabled: [.builtin(0), .builtin(1), .builtin(2)]
        ) == nil)
    }

    @Test("with no anchor present the id folds in at the front")
    func foldsAtFrontWhenNoAnchor() throws {
        let order = [7, 6].map { ToolbarItemID.builtin($0) } // tab, escape only
        let widened = try #require(migration.foldingNewlyConfigurable(
            shift, after: anchors, order: order, enabled: order
        ))
        #expect(widened.order == [.builtin(3), .builtin(7), .builtin(6)])
        #expect(widened.enabled.contains(shift))
    }

    @Test("folded layout round-trips through the reducer without dropping the id")
    func roundTripsThroughReducer() throws {
        let configurable = [0, 1, 2, 3, 6, 7].map { ToolbarItemID.builtin($0) }
        let reducer = TerminalAccessoryLayoutReducer(configurable: configurable)
        let order = [0, 1, 2, 7, 6].map { ToolbarItemID.builtin($0) }
        let widened = try #require(migration.foldingNewlyConfigurable(
            shift, after: anchors, order: order, enabled: order
        ))
        let layout = reducer.load(savedOrder: widened.order, savedEnabled: widened.enabled)
        #expect(layout.order.contains(shift))
        #expect(layout.enabled.contains(shift))
        // shift sits between command(2) and the user's first shortcut.
        let commandIndex = try #require(layout.order.firstIndex(of: .builtin(2)))
        #expect(layout.order[commandIndex + 1] == shift)
    }
}
