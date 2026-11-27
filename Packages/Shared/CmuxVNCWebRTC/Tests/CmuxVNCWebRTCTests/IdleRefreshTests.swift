@testable import CmuxVNCWebRTC
import Testing

/// A still screen's last picture is encoded again on a back-off (RFD 0088 slice 3b): soon after a change, then
/// every 4 s, where it used to be every 500 ms whatever the screen did.
struct IdleRefreshTests {
    private static let ms: UInt64 = 1_000_000

    /// The refresh times a still screen gets after one change, stepping the clock 250 ms as the host's loop does.
    private static func refreshes(over seconds: UInt64) -> [UInt64] {
        var lastPush: UInt64 = 0
        var times: [UInt64] = []
        for now in stride(from: 250 * ms, through: seconds * 1000 * ms, by: Int(250 * ms)) {
            if ScreenStreamHost.idleRefreshDue(sinceChangeNs: now, sincePushNs: now - lastPush) {
                times.append(now / ms)
                lastPush = now
            }
        }
        return times
    }

    @Test func refreshesSoonAfterAChangeThenBacksOff() {
        let times = Self.refreshes(over: 10)
        #expect(Array(times.prefix(4)) == [500, 1000, 2000, 4000])
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps == gaps.sorted(), "the gaps only grow: \(times)")
        #expect(gaps.allSatisfy { $0 <= 4000 })
    }

    @Test func aStillMinuteCostsAboutFifteenFrames() {
        // At the old 500 ms refresh it was 120.
        let count = Self.refreshes(over: 60).count
        #expect((14 ... 22).contains(count), "\(count) refreshes in a still minute")
    }

    @Test func neverFasterThanTheFloor() {
        #expect(!ScreenStreamHost.idleRefreshDue(sinceChangeNs: 0, sincePushNs: 400 * Self.ms))
        #expect(ScreenStreamHost.idleRefreshDue(sinceChangeNs: 0, sincePushNs: 450 * Self.ms))
        #expect(!ScreenStreamHost.idleRefreshDue(sinceChangeNs: 3600_000 * Self.ms, sincePushNs: 3999 * Self.ms))
        #expect(ScreenStreamHost.idleRefreshDue(sinceChangeNs: 3600_000 * Self.ms, sincePushNs: 4000 * Self.ms))
    }
}
