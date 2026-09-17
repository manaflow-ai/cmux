import Testing
@testable import CmuxNotifications

@Suite("Application frontmost policy")
struct ApplicationFrontmostPolicyTests {
    private let policy = ApplicationFrontmostPolicy()

    @Test("accepts an active application whose process is frontmost")
    func acceptsActiveMatchingProcess() {
        #expect(
            policy.isCurrentApplicationFrontmost(
                appIsActive: true,
                frontmostProcessIdentifier: 42,
                currentProcessIdentifier: 42
            )
        )
    }

    @Test("rejects an active application when another process is frontmost")
    func rejectsAnotherFrontmostProcess() {
        #expect(
            !policy.isCurrentApplicationFrontmost(
                appIsActive: true,
                frontmostProcessIdentifier: 84,
                currentProcessIdentifier: 42
            )
        )
    }

    @Test("rejects an active application when the frontmost process is unknown")
    func rejectsMissingFrontmostProcess() {
        #expect(
            !policy.isCurrentApplicationFrontmost(
                appIsActive: true,
                frontmostProcessIdentifier: nil,
                currentProcessIdentifier: 42
            )
        )
    }

    @Test("rejects an inactive application even when its process matches")
    func rejectsInactiveMatchingProcess() {
        #expect(
            !policy.isCurrentApplicationFrontmost(
                appIsActive: false,
                frontmostProcessIdentifier: 42,
                currentProcessIdentifier: 42
            )
        )
    }
}
