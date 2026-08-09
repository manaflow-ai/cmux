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

        #expect(!boundary.shouldApply(rawTitle: seededTitle))
        #expect(boundary.observe(shellState: .commandRunning) == nil)
        #expect(!boundary.shouldApply(rawTitle: seededTitle))
        #expect(boundary.shouldApply(rawTitle: "Resumed Codex session"))
        #expect(!boundary.isReleased)
    }

    @Test func userCommandReleasesBufferedTitle() {
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: nil,
            shellState: .promptIdle
        )

        #expect(!boundary.shouldApply(rawTitle: "cd /tmp/cmux"))
        #expect(boundary.observe(shellState: .commandRunning) == "cd /tmp/cmux")
        #expect(boundary.isReleased)
        #expect(boundary.shouldApply(rawTitle: "/tmp/cmux"))
    }

    @Test func alreadyRunningUnseededShellStartsReleased() {
        var boundary = RestoredPanelTitleBoundary(
            internallySeededInput: nil,
            shellState: .commandRunning
        )

        #expect(boundary.isReleased)
        #expect(boundary.shouldApply(rawTitle: "Genuine running command"))
    }
}
