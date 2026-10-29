import CmuxNextCompat
import Testing

/// CmuxNextCompat's platform layer: importing the module gives the C library and `Logger` (this file imports
/// neither Darwin nor os).
@MainActor @Suite struct PlatformLibcLoggerTests {
    @Test func libcComesWithTheModule() {
        #expect(getpid() > 0)
        #expect(STDERR_FILENO == 2)
    }

    /// The main actor runs on the main thread; a cooperative pool thread is not it.
    @Test func mainThreadIsTheMainThread() async {
        #expect(pthread_main_np() == 1)
        #expect(await Self.onPoolThread() == 0)
    }

    /// `pthread_main_np` read on a cooperative pool thread.
    @concurrent nonisolated private static func onPoolThread() async -> Int32 {
        pthread_main_np()
    }

    /// The `os.Logger` call shapes cmux-next uses compile against the module alone.
    @Test func loggerSurfaceComesWithTheModule() {
        let logger = Logger(subsystem: "com.cmuxterm.tests", category: "platform")
        let count = 3
        let id: UInt32 = 0xBEEF
        logger.debug("count \(count, privacy: .public)")
        logger.info("ratio \(0.5, format: .fixed(precision: 2), privacy: .public) \(true)")
        // os.Logger rejects .hex on a signed integer at compile time, so the hex shape logs an unsigned one.
        logger.notice("path \("/tmp", privacy: .private) id \(id, format: .hex, align: .right(columns: 4))")
    }
}
