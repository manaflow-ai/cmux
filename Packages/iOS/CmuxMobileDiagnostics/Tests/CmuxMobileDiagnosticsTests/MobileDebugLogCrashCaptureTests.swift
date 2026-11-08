#if DEBUG
import Darwin
import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDebugLogCrashCaptureTests {
    @Test func exceptionRecordFormatsCrashAndStackFrames() {
        let record = MobileDebugLogCrashCapture.exceptionRecord(
            name: "ExampleException",
            reason: "example reason",
            stack: [
                "0   cmux  first",
                "1   cmux  second",
            ]
        )

        #expect(record == """
        CRASH uncaught-exception name=ExampleException reason=example reason
          0   cmux  first
          1   cmux  second

        """)
    }

    @Test func signalRecordsContainExpectedPreRenderedLines() throws {
        let records = MobileDebugLogCrashCapture.signalRecordDefinitions
        let expected: [(signo: Int32, name: String)] = [
            (SIGABRT, "SIGABRT"),
            (SIGBUS, "SIGBUS"),
            (SIGFPE, "SIGFPE"),
            (SIGILL, "SIGILL"),
            (SIGSEGV, "SIGSEGV"),
            (SIGTRAP, "SIGTRAP"),
            (SIGSYS, "SIGSYS"),
        ]

        #expect(records.count == expected.count)
        #expect(Set(records.map(\.signo)).count == expected.count)

        for expectedRecord in expected {
            let record = try #require(records.first { $0.signo == expectedRecord.signo })
            #expect(record.name == expectedRecord.name)
            let expectedLine = MobileDebugLogCrashCapture.renderedSignalRecord(
                signo: expectedRecord.signo,
                name: expectedRecord.name
            )
            let bytes = try #require(
                MobileDebugLogCrashCapture.installedSignalRecordBytes(
                    for: expectedRecord.signo
                )
            )
            let line = String(decoding: bytes, as: UTF8.self)
            #expect(line == expectedLine)
            #expect(line.hasSuffix("\n"))
        }
    }

    @Test func previousSignalActionStorageHasOneSlotPerSignal() {
        #expect(
            MobileDebugLogCrashCapture.preparedPreviousSignalActionSlotCount()
                == MobileDebugLogCrashCapture.signalRecordDefinitions.count
        )
    }
}
#endif
