import Foundation
@testable import CmuxUpdater

struct ImmediateUpdateClock: UpdateClock {
    func sleep(for duration: Duration) async throws {}
}
