#if DEBUG
import Darwin
import Foundation

/// Crash-time writer for the DEBUG iOS durable debug log.
final class MobileDebugLogCrashCapture {
    private init() {}

    // Written once during install before handlers can run, then read by crash
    // handlers. The macOS 14 package floor rules out Synchronization.Atomic.
    nonisolated(unsafe) private static var logFileDescriptor: Int32 = -1

    // Install runs during debug-log setup and is not called concurrently.
    // Keeping this nonisolated avoids locks in the crash-capture path.
    nonisolated(unsafe) private static var installed = false

    // Captured before replacing the uncaught-exception handler; invoked after
    // this logger writes its record so existing crash handling still runs.
    nonisolated(unsafe) private static var previousExceptionHandler: NSUncaughtExceptionHandler?

    static let signalRecords: [(signo: Int32, name: String, bytes: ContiguousArray<UInt8>)] = [
        signalRecord(signo: SIGABRT, name: "SIGABRT"),
        signalRecord(signo: SIGBUS, name: "SIGBUS"),
        signalRecord(signo: SIGFPE, name: "SIGFPE"),
        signalRecord(signo: SIGILL, name: "SIGILL"),
        signalRecord(signo: SIGSEGV, name: "SIGSEGV"),
        signalRecord(signo: SIGTRAP, name: "SIGTRAP"),
        signalRecord(signo: SIGSYS, name: "SIGSYS"),
    ]

    private static let exceptionHandler: @convention(c) (NSException) -> Void = { exception in
        MobileDebugLogCrashCapture.handleUncaughtException(exception)
    }

    private static let signalHandler: @convention(c) (Int32) -> Void = { signo in
        let fd = MobileDebugLogCrashCapture.logFileDescriptor
        if fd >= 0 {
            for record in MobileDebugLogCrashCapture.signalRecords where record.signo == signo {
                record.bytes.withUnsafeBufferPointer { buffer in
                    if let baseAddress = buffer.baseAddress {
                        _ = Darwin.write(fd, baseAddress, buffer.count)
                    }
                }
                break
            }
        }
        _ = Darwin.signal(signo, SIG_DFL)
        _ = Darwin.raise(signo)
    }

    static func install(logFileDescriptor: Int32) {
        guard !installed else {
            return
        }
        let duplicatedDescriptor = Darwin.dup(logFileDescriptor)
        guard duplicatedDescriptor >= 0 else {
            return
        }

        _ = signalRecords.count
        Self.logFileDescriptor = duplicatedDescriptor
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(exceptionHandler)
        installSignalHandlers()
        installed = true
    }

    static func exceptionRecord(name: String, reason: String, stack: [String]) -> String {
        var lines = ["CRASH uncaught-exception name=\(name) reason=\(reason)"]
        lines.append(contentsOf: stack.map { "  \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func handleUncaughtException(_ exception: NSException) {
        let record = exceptionRecord(
            name: exception.name.rawValue,
            reason: exception.reason ?? "",
            stack: exception.callStackSymbols
        )
        writeCrashRecord(record)
        previousExceptionHandler?(exception)
    }

    private static func installSignalHandlers() {
        for record in signalRecords {
            var action = sigaction()
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            action.__sigaction_u.__sa_handler = signalHandler
            _ = sigaction(record.signo, &action, nil)
        }
    }

    private static func writeCrashRecord(_ record: String) {
        let fd = logFileDescriptor
        guard fd >= 0 else {
            return
        }
        let bytes = Array(record.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                _ = Darwin.write(fd, baseAddress, buffer.count)
            }
        }
    }

    private static func signalRecord(
        signo: Int32,
        name: String
    ) -> (signo: Int32, name: String, bytes: ContiguousArray<UInt8>) {
        let line = "CRASH signal=\(signo) name=\(name)\n"
        return (signo: signo, name: name, bytes: ContiguousArray(line.utf8))
    }
}
#endif
