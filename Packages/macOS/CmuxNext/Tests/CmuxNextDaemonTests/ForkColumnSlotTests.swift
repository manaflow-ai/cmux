import CmuxNextDaemon
import Testing

/// Fork to New Column Right / Left (u18673): where the fork's column opens beside the chat's.
@Suite struct ForkColumnSlotTests {
    static func column(_ id: UInt64, docked: Bool = false) -> ColumnSnapshot {
        ColumnSnapshot(id: ColumnID(rawValue: id), width: 0.5, layout: .leaf(PaneID(rawValue: id)),
                       dock: docked ? DockSnapshot(edge: .left, mode: .docked) : nil)
    }

    @Test func rightOpensAfterTheChatsColumn() {
        let columns = [Self.column(1), Self.column(2)]
        #expect(ForkColumnSlot(columns: columns, own: ColumnID(rawValue: 1), left: false) == .after(ColumnID(rawValue: 1)))
    }

    @Test func leftOpensAfterThePreviousColumn() {
        let columns = [Self.column(1), Self.column(2)]
        #expect(ForkColumnSlot(columns: columns, own: ColumnID(rawValue: 2), left: true) == .after(ColumnID(rawValue: 1)))
    }

    @Test func leftOfTheFirstColumnOpensRightThenTheChatMovesRight() {
        let columns = [Self.column(1), Self.column(2)]
        #expect(ForkColumnSlot(columns: columns, own: ColumnID(rawValue: 1), left: true) == .afterThenMoveRight(ColumnID(rawValue: 1)))
    }

    @Test func aDockedColumnBeforeIsNotASlot() {
        let columns = [Self.column(1, docked: true), Self.column(2)]
        #expect(ForkColumnSlot(columns: columns, own: ColumnID(rawValue: 2), left: true) == .afterThenMoveRight(ColumnID(rawValue: 2)))
    }

    @Test func aChatWithoutAScrollingColumnLetsTheDaemonPlaceIt() {
        #expect(ForkColumnSlot(columns: [], own: nil, left: true) == .after(nil))
    }
}
