import Foundation
import Testing
import CmuxNextPages

@Suite struct PageCrashReloadsTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aPageThatKeepsCrashingStopsReloading() {
        var reloads = PageCrashReloads()
        let decisions = (0..<5).map { reloads.shouldReload(at: start.addingTimeInterval(Double($0))) }
        #expect(decisions == [true, true, true, false, false])
    }

    @Test func crashesOutsideTheWindowAreForgotten() {
        var reloads = PageCrashReloads()
        let decisions = (0..<PageCrashReloads.limit).map { reloads.shouldReload(at: start.addingTimeInterval(Double($0))) }
        #expect(decisions.allSatisfy { $0 })
        let later = reloads.shouldReload(at: start.addingTimeInterval(PageCrashReloads.window + 1))
        #expect(later)
    }
}
