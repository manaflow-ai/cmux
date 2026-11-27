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

        let appliesSeededTitleBeforeBootstrap = boundary.shouldApply(rawTitle: seededTitle)
        #expect(!appliesSeededTitleBeforeBootstrap)

        let bufferedTitle = boundary.observe(shellState: .commandRunning)
        #expect(bufferedTitle == nil)

        let appliesSeededTitleDuringBootstrap = boundary.shouldApply(rawTitle: seededTitle)
        #expect(!appliesSeededTitleDuringBootstrap)

        let appliesResumedAgentTitle = boundary.shouldApply(rawTitle: "Resumed Codex session")
        #expect(appliesResumedAgentTitle)
        #expect(!boundary.isReleased)
    }

    @Test func userCommandReleasesBufferedTitle() {
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: nil,
            shellState: .promptIdle
        )

        let appliesPreexecTitle = boundary.shouldApply(rawTitle: "cd /tmp/cmux")
        #expect(!appliesPreexecTitle)

        let bufferedTitle = boundary.observe(shellState: .commandRunning)
        #expect(bufferedTitle == "cd /tmp/cmux")
        #expect(boundary.isReleased)

        let appliesReleasedTitle = boundary.shouldApply(rawTitle: "/tmp/cmux")
        #expect(appliesReleasedTitle)
    }

    @Test func alreadyRunningUnseededShellStartsReleased() {
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: nil,
            shellState: .commandRunning
        )

        let appliesRunningCommandTitle = boundary.shouldApply(rawTitle: "Genuine running command")

        #expect(boundary.isReleased)
        #expect(appliesRunningCommandTitle)
    }
}
