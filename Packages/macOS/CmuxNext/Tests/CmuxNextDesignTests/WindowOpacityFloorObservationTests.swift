@testable import CmuxNextDesign
import Observation
import Testing

/// Settings' host lists re-send when something they read changes (an observation stream). The
/// Opacity slider's floor (`windowOpacityFloor`) comes from a theme scope, which is not
/// observable, so after a picture change the page kept the previous picture's floor (#22378
/// review). Reading the floor or the shown opacity now registers the scope's backdrop revision.
@MainActor
struct WindowOpacityFloorObservationTests {
    private final class Flag: @unchecked Sendable { var raised = false }

    private func observing(_ read: () -> Void, while change: () throws -> Void) rethrows -> Bool {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.raised = true }
        try change()
        return flag.raised
    }

    @Test func aNewPictureChangesTheObservedFloor() throws {
        let scope = ThemeScope(level: .room)
        let work = try #require(BackdropSelection(id: "van-gogh-starry-night"))
        #expect(try observing({ _ = scope.windowOpacityFloor }, while: { scope.setBackdropSelection(work) }))
        #expect(scope.windowOpacityFloor != nil)
        #expect(observing({ _ = scope.windowOpacityFloor }, while: { scope.setBackdropSelection(nil) }))
        #expect(scope.windowOpacityFloor == nil)
    }

    /// A picture chosen on a parent (the app's All Workspaces pick) reaches its children's reads.
    @Test func aPictureOnTheParentChangesAChildsObservedResting() throws {
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        let work = try #require(BackdropSelection(id: "van-gogh-starry-night"))
        #expect(try observing({ _ = workspace.shownWindowOpacity }, while: { room.setBackdropSelection(work) }))
    }
}
