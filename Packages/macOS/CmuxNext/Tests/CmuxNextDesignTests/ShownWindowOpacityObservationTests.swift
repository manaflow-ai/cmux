@testable import CmuxNextDesign
import Observation
import Testing

/// Settings' host lists re-send when something they read changes (an observation stream). The
/// Opacity slider's resting value (`shownWindowOpacity`) comes from a theme scope, which is not
/// observable, so reading it registers the scope's backdrop revision.
@MainActor
struct ShownWindowOpacityObservationTests {
    // Nonisolated: onChange runs outside the main actor (this target is main-actor by default).
    private nonisolated final class Flag: @unchecked Sendable { var raised = false }

    private func observing(_ read: () -> Void, while change: () throws -> Void) rethrows -> Bool {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.raised = true }
        try change()
        return flag.raised
    }

    @Test func aNewPictureChangesTheObservedShownOpacity() throws {
        let scope = ThemeScope(level: .room)
        let work = try #require(BackdropSelection(id: "van-gogh-starry-night"))
        #expect(try observing({ _ = scope.shownWindowOpacity }, while: { scope.setBackdropSelection(work) }))
        #expect(observing({ _ = scope.shownWindowOpacity }, while: { scope.setBackdropSelection(nil) }))
    }

    /// A picture chosen on a parent (the app's All Workspaces pick) reaches its children's reads.
    @Test func aPictureOnTheParentChangesAChildsObservedResting() throws {
        let room = ThemeScope(level: .room)
        let workspace = ThemeScope(level: .workspace, parent: room)
        let work = try #require(BackdropSelection(id: "van-gogh-starry-night"))
        #expect(try observing({ _ = workspace.shownWindowOpacity }, while: { room.setBackdropSelection(work) }))
    }
}
