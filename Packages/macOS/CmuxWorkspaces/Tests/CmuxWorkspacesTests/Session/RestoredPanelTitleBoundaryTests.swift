import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite struct RestoredPanelTitleBoundaryTests {
    @Test func internallySeededTitleStaysInertWhileGenuineAgentTitleApplies() {
        let seededInput = " internal bootstrap payload\n"
        let seededTitle = seededInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: seededInput,
            shellState: .promptIdle
        )

        let rejectsInitialSeededTitle = !boundary.shouldApply(rawTitle: seededTitle)
        let titleReleasedByCommand = boundary.observe(shellState: .commandRunning)
        let rejectsRepeatedSeededTitle = !boundary.shouldApply(rawTitle: seededTitle)
        let acceptsAgentTitle = boundary.shouldApply(rawTitle: "Resumed Codex session")

        #expect(rejectsInitialSeededTitle)
        #expect(titleReleasedByCommand == nil)
        #expect(rejectsRepeatedSeededTitle)
        #expect(acceptsAgentTitle)
        #expect(!boundary.isReleased)
    }

    @Test func userCommandReleasesBufferedTitle() {
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: nil,
            shellState: .promptIdle
        )

        let rejectsBufferedTitle = !boundary.shouldApply(rawTitle: "cd /tmp/cmux")
        let releasedTitle = boundary.observe(shellState: .commandRunning)

        #expect(rejectsBufferedTitle)
        #expect(releasedTitle == "cd /tmp/cmux")
        #expect(boundary.isReleased)
        let acceptsLaterTitle = boundary.shouldApply(rawTitle: "/tmp/cmux")
        #expect(acceptsLaterTitle)
    }

    @Test func alreadyRunningUnseededShellStartsReleased() {
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: nil,
            shellState: .commandRunning
        )

        #expect(boundary.isReleased)
        let acceptsRunningTitle = boundary.shouldApply(rawTitle: "Genuine running command")
        #expect(acceptsRunningTitle)
    }
}
