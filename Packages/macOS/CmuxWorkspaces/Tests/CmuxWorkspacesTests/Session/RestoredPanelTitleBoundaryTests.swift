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

        let acceptsSeededTitleBeforeCommand = boundary.shouldApply(rawTitle: seededTitle)
        #expect(!acceptsSeededTitleBeforeCommand)
        let bufferedTitle = boundary.observe(shellState: .commandRunning)
        #expect(bufferedTitle == nil)
        let acceptsSeededTitleDuringBootstrap = boundary.shouldApply(rawTitle: seededTitle)
        #expect(!acceptsSeededTitleDuringBootstrap)
        let acceptsAgentTitle = boundary.shouldApply(rawTitle: "Resumed Codex session")
        #expect(acceptsAgentTitle)
        #expect(!boundary.isReleased)
    }

    @Test func userCommandReleasesBufferedTitle() {
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: nil,
            shellState: .promptIdle
        )

        let acceptsCommandTitleBeforeRunning = boundary.shouldApply(rawTitle: "cd /tmp/cmux")
        #expect(!acceptsCommandTitleBeforeRunning)
        let releasedTitle = boundary.observe(shellState: .commandRunning)
        #expect(releasedTitle == "cd /tmp/cmux")
        #expect(boundary.isReleased)
        let acceptsSubsequentTitle = boundary.shouldApply(rawTitle: "/tmp/cmux")
        #expect(acceptsSubsequentTitle)
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
