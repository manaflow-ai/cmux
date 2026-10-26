@testable import CmuxNextCrashReporting
import Foundation
import Sentry
import Testing

/// A registered thread's hang is one Sentry event tagged `hang.thread`, on a thread that carries the
/// name and the stack, with the debug images that symbolicate it (task p09-observability-068).
@Suite struct ThreadHangReportTests {
    /// Two return addresses in this test binary, so the event maps them to a loaded image.
    private static func addresses() -> [UInt] {
        let anchor = UInt(bitPattern: unsafeBitCast(threadHangEventTestAnchor as @convention(c) () -> Void, to: UnsafeRawPointer.self))
        return [anchor + 4, anchor + 8]
    }

    @Test func theEventNamesTheThreadAndCarriesItsStack() throws {
        let addresses = Self.addresses()
        let event = ThreadHangEvent(thread: "terminal-output", overdue: .milliseconds(1_500), addresses: addresses).event()
        #expect(event.level == .error)
        #expect(event.tags?["hang.thread"] == "terminal-output")
        #expect(event.tags?["hang_source"] == "hang_watch")
        let exception = try #require(event.exceptions?.first)
        #expect(exception.type == "ThreadHang")
        #expect(exception.value.contains("terminal-output"))
        #expect(exception.mechanism?.type == "hang_watch")
        let thread = try #require(event.threads?.first)
        #expect(event.threads?.count == 1)
        #expect(thread.name == "terminal-output")
        #expect(thread.crashed?.boolValue == true)
        #expect(thread.isMain?.boolValue == false)
        // Sentry frames run outermost first.
        let frames = try #require(thread.stacktrace?.frames)
        let expected: [String?] = addresses.reversed().map { "0x" + String($0, radix: 16) }
        #expect(frames.map(\.instructionAddress) == expected)
        #expect(event.debugMeta?.isEmpty == false, "no debug image for the stack's addresses")
        #expect(event.fingerprint?.contains("terminal-output") == true)
    }
}

/// An address inside this test binary.
@inline(never)
private func threadHangEventTestAnchor() {}
