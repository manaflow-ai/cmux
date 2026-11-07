import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Opt-in team usage sharing (Leo 2026-11-07): it needs recording on, its own setting and this
/// Mac's own consent; the daemon's share marker follows the decision; an upload runs once the
/// marker is on and at most once per six hours, on launch and on resigning active.
@MainActor @Suite struct UsageSharingTests {
    // MARK: Decision

    @Test(arguments: [
        (true, true, true, UsageSharing.Decision.share),
        (true, true, false, .confirm),
        (true, false, true, .off),
        (true, false, false, .off),
        (false, true, true, .off),
        (false, true, false, .off),
        (false, false, true, .off),
    ])
    func sharingNeedsRecordingOnAndTheSettingAndThisMacsConsent(recordingOn: Bool, settingOn: Bool, consented: Bool,
                                                               expected: UsageSharing.Decision) {
        #expect(UsageSharing.decision(recordingOn: recordingOn, settingOn: settingOn, consented: consented) == expected)
    }

    /// Recording's own decision needs its setting and consent; sharing needs that one to record.
    @Test func sharingNeedsBothConsents() {
        for recordingConsented in [false, true] {
            let recording = UsageRecorder.decision(settingOn: true, consented: recordingConsented, managedOff: false)
            let sharing = UsageSharing.decision(recordingOn: recording == .record, settingOn: true, consented: true)
            #expect(sharing == (recordingConsented ? .share : .off))
        }
        let managed = UsageRecorder.decision(settingOn: true, consented: true, managedOff: true)
        #expect(UsageSharing.decision(recordingOn: managed == .record, settingOn: true, consented: true) == .off)
    }

    // MARK: The 6 h gate

    @Test func anUploadIsDueFirstThenEverySixHours() {
        let start = Date(timeIntervalSince1970: 1_762_500_000)
        #expect(UsageSharing.uploadDue(now: start, last: nil))
        #expect(!UsageSharing.uploadDue(now: start.addingTimeInterval(60), last: start))
        #expect(!UsageSharing.uploadDue(now: start.addingTimeInterval(6 * 3600 - 1), last: start))
        #expect(UsageSharing.uploadDue(now: start.addingTimeInterval(6 * 3600), last: start))
        // A clock set back past the last upload does not stop uploads for good.
        #expect(UsageSharing.uploadDue(now: start.addingTimeInterval(-60), last: start))
    }

    // MARK: Flow

    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_762_500_000)
    }

    private static func sharing(_ log: SharingLog, clock: TestClock, defaults: UserDefaults) -> UsageSharing {
        let ports = UsageSharing.Ports(
            ask: { _, _, _, _ in false },
            setSharing: { on in log.calls.withLock { $0.append("set-sharing \(on)") } },
            upload: {
                log.calls.withLock { $0.append("upload") }
                return true
            },
            now: { clock.now })
        return UsageSharing(ports: ports, defaults: defaults)
    }

    private static func defaults(consented: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "cn-usage-sharing-\(UUID().uuidString)") ?? .standard
        if consented { defaults.set(Date(), forKey: UsageSharing.consentKey) }
        return defaults
    }

    private static func settle(_ sharing: UsageSharing, until done: () -> Bool) async {
        for _ in 0..<50 where !done() || sharing.isUploading { await Task.yield() }
    }

    @Test func theMarkerFollowsTheDecisionAndTheFirstSwitchUploads() async {
        let log = SharingLog()
        let clock = TestClock()
        let defaults = Self.defaults(consented: true)
        let sharing = Self.sharing(log, clock: clock, defaults: defaults)
        sharing.setting(true)
        await Self.settle(sharing) { log.all == ["set-sharing false"] }
        #expect(log.all == ["set-sharing false"])

        sharing.recording(true)
        await Self.settle(sharing) { log.all.count == 3 }
        #expect(log.all == ["set-sharing false", "set-sharing true", "upload"])
        #expect(defaults.object(forKey: UsageSharing.lastUploadKey) as? Date == clock.now)

        // Within six hours a resign uploads nothing; after them it does.
        clock.now = clock.now.addingTimeInterval(3600)
        sharing.appResigned()
        await Self.settle(sharing) { true }
        #expect(log.all.count == 3)
        clock.now = clock.now.addingTimeInterval(5 * 3600)
        sharing.appResigned()
        await Self.settle(sharing) { log.all.count == 4 }
        #expect(log.all.last == "upload")

        // Recording off takes sharing off; a resign then uploads nothing.
        sharing.recording(false)
        await Self.settle(sharing) { log.all.count == 5 }
        #expect(log.all.last == "set-sharing false")
        clock.now = clock.now.addingTimeInterval(7 * 3600)
        sharing.appResigned()
        await Self.settle(sharing) { true }
        #expect(log.all.count == 5)
    }

    /// Sharing off during an upload ends it (Codex review of c9cdeb6e): the upload's task is
    /// cancelled, which kills the `cmux usage upload` process, and none other starts.
    @Test func turningSharingOffCancelsTheRunningUpload() async {
        let log = SharingLog()
        let ports = UsageSharing.Ports(
            ask: { _, _, _, _ in false },
            setSharing: { on in log.calls.withLock { $0.append("set-sharing \(on)") } },
            upload: {
                log.calls.withLock { $0.append("upload") }
                while !Task.isCancelled { await Task.yield() }
                log.calls.withLock { $0.append("upload cancelled") }
                return false
            })
        let sharing = UsageSharing(ports: ports, defaults: Self.defaults(consented: true))
        sharing.setting(true)
        sharing.recording(true)
        for _ in 0..<50 where !log.all.contains("upload") { await Task.yield() }
        #expect(sharing.isUploading)

        sharing.setting(false)
        #expect(!sharing.isUploading)
        for _ in 0..<50 where !log.all.contains("upload cancelled") { await Task.yield() }
        #expect(log.all.contains("upload cancelled"))
        #expect(log.all.filter { $0 == "upload" }.count == 1)
    }

    @Test func noConsentNoMarkerAndNoUpload() async {
        let log = SharingLog()
        let defaults = Self.defaults(consented: false)
        let sharing = Self.sharing(log, clock: TestClock(), defaults: defaults)
        sharing.recording(true)
        sharing.setting(true)
        #expect(sharing.decision == .confirm)
        sharing.appResigned()
        await Self.settle(sharing) { log.all == ["set-sharing false"] }
        #expect(log.all == ["set-sharing false"])
        #expect(defaults.object(forKey: UsageSharing.lastUploadKey) == nil)
    }

    @Test func turningTheSettingOffRemovesThisMacsConsent() {
        let defaults = Self.defaults(consented: true)
        let sharing = Self.sharing(SharingLog(), clock: TestClock(), defaults: defaults)
        sharing.setting(false)
        #expect(!UsageSharing.consented(defaults))
    }

    @Test func onlyThePersonsTrueWriteOfTheSharingKeyRecordsConsent() {
        let defaults = Self.defaults(consented: false)
        _ = UsageSharing.recordUserWrite(defaults: defaults, path: UsageRecordingSetting.path, value: .bool(true))
        #expect(!UsageSharing.consented(defaults))
        let undo = UsageSharing.recordUserWrite(defaults: defaults, path: UsageSharingSetting.path, value: .bool(true))
        #expect(UsageSharing.consented(defaults))
        undo?()
        #expect(!UsageSharing.consented(defaults))
    }
}

private final class SharingLog: Sendable {
    let calls = Mutex<[String]>([])
    var all: [String] { calls.withLock { $0 } }
}
