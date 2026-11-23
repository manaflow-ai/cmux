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

    /// A Chief panic may quote chat text (a string slice panic prints the string): only its
    /// location, process and backtrace are sent.
    @Test func aChiefPanicSendsNoMessageText() throws {
        let data = try line(["message": "byte index 5 is not a char boundary; it is inside 'é' of `please fix the login bug`",
                             "location": "src/brain/turns.rs:10:5", "process": "optchat-chief"])
        let event = try #require(OwnerPanicForwarder.event(fromLine: data, source: .chief))
        let sent = [event.message?.formatted ?? ""] + (event.exceptions ?? []).map { $0.value ?? "" }
        #expect(sent.allSatisfy { !$0.contains("login bug") }, "\(sent)")
        #expect(event.tags?["process"] == "optchat-chief")
        #expect(event.fingerprint == ["chief-panic", "src/brain/turns.rs:10:5"])
    }
}
