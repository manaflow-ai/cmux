import Foundation
@testable import CmuxRemoteSession

/// A coordinator under test plus the scratch directory backing its relay socket.
struct ReadinessCoordinatorFixture {
    let coordinator: RemoteSessionCoordinator
    let scratchDirectory: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }
}
