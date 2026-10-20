import Foundation
@testable import CmuxGit

actor TestWorkspaceChangesClock: WorkspaceChangesClock {
    private var instant: Duration = .zero

    func now() -> Duration {
        instant
    }

    func advance(by duration: Duration) {
        instant += duration
    }
}
