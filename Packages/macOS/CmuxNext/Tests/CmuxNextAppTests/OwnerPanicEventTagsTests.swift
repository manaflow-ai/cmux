@testable import CmuxNextCrashReporting
import Foundation
import Sentry
import Testing

/// Tester rollout (plans/cmux-next/tui-tester-rollout.md #12): a cmux-tui owner
/// panic line names its release, build, OS and CPU, and the Sentry event
/// carries them as tags so crashes group by release and platform.
@Suite struct OwnerPanicEventTagsTests {
    private func line(_ record: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: record)
    }

    @Test func theBuildFactsBecomeTags() throws {
        let data = try line([
            "session": "main", "message": "boom", "location": "src/a.rs:1:2", "thread": "worker",
            "version": "0.13.5", "build_identity": "abc123", "os": "linux", "arch": "aarch64",
            "test": false, "backtrace": "",
        ])
        let event = try #require(OwnerPanicForwarder.event(fromLine: data))
        let tags = event.tags ?? [:]
        #expect(tags["tui_version"] == "0.13.5")
        #expect(tags["tui_build"] == "abc123")
        #expect(tags["tui_os"] == "linux")
        #expect(tags["tui_arch"] == "aarch64")
    }

    @Test func anOlderLineWithoutTheFactsStillReports() throws {
        let data = try line(["message": "boom", "location": "src/a.rs:1:2", "version": "0.1.0"])
        let event = try #require(OwnerPanicForwarder.event(fromLine: data))
        let tags = event.tags ?? [:]
        #expect(tags["tui_version"] == "0.1.0")
        #expect(tags["tui_build"] == nil)
    }
}
