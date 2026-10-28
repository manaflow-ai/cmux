import CmuxNextCompat
import Testing

/// CmuxNextCompat's platform layer: importing the module gives the C library and `Logger`
/// on every platform (this file imports neither Darwin, Glibc nor os), `pthread_main_np` tells the main thread
/// apart on Linux too, and the Linux `Logger` writes what the unified log would: privacy redactions, formats,
/// alignment, the level mapping, and no value read for a level that is off.
@MainActor @Suite struct PlatformLibcLoggerTests {
    @Test func libcComesWithTheModule() {
        #expect(getpid() > 0)
        #expect(STDERR_FILENO == 2)
    }

    /// On Darwin the main actor runs on the main thread; swift-testing on Linux runs it on another thread, so
    /// there only the pool thread is checked.
    @Test func mainThreadIsTheMainThread() async {
        #if canImport(Darwin)
        #expect(pthread_main_np() == 1)
        #endif
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

    #if !canImport(os)
    /// The lines a Linux `Logger` wrote, with their levels.
    nonisolated final class RecordingSink: LogSink {
        private let state = Mutex<[String]>([])
        let minimumLevel: OSLogType

        init(minimumLevel: OSLogType = .debug) {
            self.minimumLevel = minimumLevel
        }

        var lines: [String] { state.withLock { $0 } }

        func isEnabled(_ level: OSLogType) -> Bool {
            StandardErrorLogSink(minimumLevel: minimumLevel).isEnabled(level)
        }

        func write(level: OSLogType, subsystem: String, category: String, message: String) {
            state.withLock { $0.append("\(subsystem):\(category) \(level.name) \(message)") }
        }
    }

    /// Counts the reads of a logged value.
    nonisolated final class ReadCounter {
        private(set) var reads = 0

        func read() -> Int {
            reads += 1
            return reads
        }
    }

    @Test func privacyRedactsTextByDefaultAndWritesNumbers() {
        let sink = RecordingSink()
        let logger = Logger(subsystem: "s", category: "c", sink: sink)
        let name = "secret"
        logger.notice("a \(name) b \(name, privacy: .public) c \(42) d \(42, privacy: .private) e \(true)")
        #expect(sink.lines == ["s:c default a <private> b secret c 42 d <private> e true"])
    }

    @Test func hashMaskMatchesEqualValues() {
        let sink = RecordingSink()
        let logger = Logger(subsystem: "s", category: "c", sink: sink)
        logger.error("\("one", privacy: .private(mask: .hash)) \("one", privacy: .sensitive(mask: .hash)) \("two", privacy: .private(mask: .hash))")
        let parts = sink.lines.first?.dropFirst("s:c error ".count).split(separator: " ").map(String.init) ?? []
        #expect(parts.count == 6)
        #expect(parts[0] == "<mask.hash:")
        #expect(parts[1] == parts[3])
        #expect(parts[1] != parts[5])
    }

    @Test func formatsAndAlignment() {
        let sink = RecordingSink()
        let logger = Logger(subsystem: "s", category: "c", sink: sink)
        logger.notice("""
            [\(1.23456, format: .fixed(precision: 3), privacy: .public)]\
            [\(Float(2.5), format: .fixed(precision: 1), privacy: .public)]\
            [\(255, format: .hex, privacy: .public)]\
            [\(255, format: .hex(includePrefix: true, uppercase: true), privacy: .public)]\
            [\(-7, format: .decimal(explicitPositiveSign: true, minDigits: 3), privacy: .public)]\
            [\(7, format: .decimal(explicitPositiveSign: true), privacy: .public)]\
            [\(8, format: .octal(includePrefix: true), privacy: .public)]\
            [\(false, format: .answer, privacy: .public)]\
            [\("ab", align: .left(columns: 4), privacy: .public)]\
            [\("ab", align: .right(columns: 4), privacy: .public)]
            """)
        #expect(sink.lines == ["s:c default [1.235][2.5][ff][0XFF][-007][+7][010][NO][ab  ][  ab]"])
    }

    @Test func levelMethodsMapToTheUnifiedLogLevels() {
        let sink = RecordingSink()
        let logger = Logger(subsystem: "s", category: "c", sink: sink)
        logger.trace("t")
        logger.debug("d")
        logger.info("i")
        logger.notice("n")
        logger.log("l")
        logger.warning("w")
        logger.error("e")
        logger.critical("c")
        logger.fault("f")
        logger.log(level: .info, "li")
        #expect(sink.lines.map { $0.split(separator: " ")[1] } == [
            "debug", "debug", "info", "default", "default", "error", "error", "fault", "fault", "info",
        ])
    }

    @Test func aLevelThatIsOffReadsNoValue() {
        let sink = RecordingSink(minimumLevel: .error)
        let logger = Logger(subsystem: "s", category: "c", sink: sink)
        let counter = ReadCounter()
        logger.debug("\(counter.read())")
        logger.info("\(counter.read())")
        logger.notice("\(counter.read())")
        #expect(counter.reads == 0)
        logger.error("\(counter.read())")
        #expect(counter.reads == 1)
        #expect(sink.lines == ["s:c error 1"])
    }

    @Test func standardErrorSinkLevelComesFromItsName() {
        #expect(!StandardErrorLogSink(environmentLevel: nil).isEnabled(.info))
        #expect(StandardErrorLogSink(environmentLevel: nil).isEnabled(.default))
        #expect(StandardErrorLogSink(environmentLevel: "DEBUG").isEnabled(.debug))
        #expect(!StandardErrorLogSink(environmentLevel: "error").isEnabled(.default))
        #expect(StandardErrorLogSink(environmentLevel: "error").isEnabled(.fault))
        #expect(StandardErrorLogSink(environmentLevel: "loud").minimumLevel == .default)
    }
    #endif
}
