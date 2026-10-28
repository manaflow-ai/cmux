import Darwin
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// A watched thread's hang is one Sentry event tagged `hang.thread` with the registration's
/// name, whose one exception and one (crashed) thread carry the hung thread's stack, symbolicated from debug_meta.
struct ThreadHangReportTests {
    /// The address of `malloc`, in libsystem_malloc (the dyld shared cache on every supported macOS).
    private static func mallocAddress() -> UInt? {
        // SAFETY: dlsym reads the NUL-terminated copy of the name made for the call; RTLD_DEFAULT (-2) is a handle
        // value dlsym defines. The result is used as an integer address only.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc") else { return nil }
        return unsafe UInt(bitPattern: symbol)
    }

    @Test func theEventNamesTheThreadAndCarriesItsFrames() throws {
        let address = try #require(Self.mallocAddress())
        let event = ThreadHangEvent(thread: "daemon-reader", threadKind: "io", threadName: "cmux.daemon.reader",
                                    overrun: .milliseconds(2_340), addresses: [address, address + 8]).event()
        #expect(event.tags?["hang.thread"] == "daemon-reader")
        #expect(event.tags?["hang.thread_kind"] == "io")
        #expect(event.tags?["hang_source"] == "hang_watch")
        #expect(event.extra?["hang_overrun_ms"] as? Int == 2_340)
        #expect(event.extra?["thread_name"] as? String == "cmux.daemon.reader")
        let exception = try #require(event.exceptions?.first)
        #expect(event.exceptions?.count == 1)
        #expect(exception.type == "ThreadHang")
        #expect(exception.mechanism?.type == "hang_watch")
        #expect(exception.stacktrace?.frames.count == 2)
        #expect(exception.stacktrace?.frames.last?.instructionAddress == MainThreadHangEvent.hex(UInt64(address)),
                "Sentry frames run outermost first: the innermost frame is last")
        let thread = try #require(event.threads?.first)
        #expect(event.threads?.count == 1)
        #expect(thread.name == "cmux.daemon.reader")
        #expect(thread.crashed?.boolValue == true)
        #expect(thread.isMain?.boolValue == false)
        #expect(thread.stacktrace?.frames.count == 2)
        #expect(event.debugMeta?.count == 1, "the one image that holds both frames")
    }

    @Test func anUnnamedThreadIsShownByItsRegistration() {
        let event = ThreadHangEvent(thread: "terminal-output", threadKind: "lane", threadName: "", overrun: .seconds(2),
                                    addresses: []).event()
        #expect(event.threads?.first?.name == "terminal-output")
        #expect(event.extra?["thread_name"] == nil)
        #expect(event.tags?["hang.thread"] == "terminal-output")
    }
}
