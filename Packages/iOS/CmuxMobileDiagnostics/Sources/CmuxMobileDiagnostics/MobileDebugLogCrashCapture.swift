#if DEBUG
import Darwin
import Foundation

/// Crash-time writer for the DEBUG iOS durable debug log.
///
/// Signal crashes are written to the log, then the previously installed signal
/// action is restored and the signal is re-raised so earlier crash reporters
/// still observe the crash.
final class MobileDebugLogCrashCapture {
    private init() {}

    typealias SignalEntry = (signo: Int32, offset: Int32, length: Int32)

    // Written once during install before handlers can run, then read by crash
    // handlers. The macOS 14 package floor rules out Synchronization.Atomic.
    nonisolated(unsafe) private static var logFileDescriptor: Int32 = -1

    // Install runs during debug-log setup and is not called concurrently.
    // Keeping this nonisolated avoids locks in the crash-capture path.
    nonisolated(unsafe) private static var installed = false

    // Captured before replacing the uncaught-exception handler; invoked after
    // this logger writes its record so existing crash handling still runs.
    nonisolated(unsafe) private static var previousExceptionHandler: NSUncaughtExceptionHandler?

    // Prepared once outside signal context, then read directly by the signal
    // handler via pointer arithmetic. The allocations intentionally live for
    // the process lifetime so a crash never races deallocation.
    nonisolated(unsafe) private static var signalEntryPointer: UnsafeMutablePointer<SignalEntry>?
    nonisolated(unsafe) private static var signalEntryCount: Int32 = 0
    nonisolated(unsafe) private static var signalBytePointer: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) private static var previousSignalActionPointer: UnsafeMutablePointer<sigaction>?
    nonisolated(unsafe) private static var previousSignalActionCount: Int32 = 0

    static let signalRecordDefinitions: [(signo: Int32, name: String)] = [
        (SIGABRT, "SIGABRT"),
        (SIGBUS, "SIGBUS"),
        (SIGFPE, "SIGFPE"),
        (SIGILL, "SIGILL"),
        (SIGSEGV, "SIGSEGV"),
        (SIGTRAP, "SIGTRAP"),
        (SIGSYS, "SIGSYS"),
    ]

    private static let exceptionHandler: @convention(c) (NSException) -> Void = { exception in
        MobileDebugLogCrashCapture.handleUncaughtException(exception)
    }

    private static let signalHandler: @convention(c) (Int32) -> Void = { signo in
        let fd = MobileDebugLogCrashCapture.logFileDescriptor
        let entries = MobileDebugLogCrashCapture.signalEntryPointer
        let bytes = MobileDebugLogCrashCapture.signalBytePointer
        let previousActions = MobileDebugLogCrashCapture.previousSignalActionPointer
        let count = MobileDebugLogCrashCapture.signalEntryCount
        if fd >= 0, let entries, let bytes {
            var index: Int32 = 0
            while index < count {
                let entry = entries.advanced(by: Int(index)).pointee
                if entry.signo == signo {
                    _ = Darwin.write(
                        fd,
                        bytes.advanced(by: Int(entry.offset)),
                        Int(entry.length)
                    )
                    if let previousActions {
                        var previousAction = previousActions.advanced(by: Int(index)).pointee
                        _ = sigaction(signo, &previousAction, nil)
                    } else {
                        _ = Darwin.signal(signo, SIG_DFL)
                    }
                    _ = Darwin.raise(signo)
                    return
                }
                index += 1
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

        prepareSignalRecordStorage()
        preparePreviousSignalActionStorage()
        Self.logFileDescriptor = duplicatedDescriptor
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(exceptionHandler)
        installSignalHandlers()
        installed = true
    }

    static func updateLogFileDescriptor(_ fileDescriptor: Int32) {
        let duplicatedDescriptor = Darwin.dup(fileDescriptor)
        guard duplicatedDescriptor >= 0 else {
            return
        }
        let previousDescriptor = logFileDescriptor
        logFileDescriptor = duplicatedDescriptor
        if previousDescriptor >= 0 {
            _ = Darwin.close(previousDescriptor)
        }
    }

    static func exceptionRecord(name: String, reason: String, stack: [String]) -> String {
        var lines = ["CRASH uncaught-exception name=\(name) reason=\(reason)"]
        lines.append(contentsOf: stack.map { "  \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderedSignalRecord(signo: Int32, name: String) -> String {
        "CRASH signal=\(signo) name=\(name)\n"
    }

    static func installedSignalRecordBytes(for signo: Int32) -> [UInt8]? {
        prepareSignalRecordStorage()
        guard let entries = signalEntryPointer, let bytes = signalBytePointer else {
            return nil
        }
        var index: Int32 = 0
        while index < signalEntryCount {
            let entry = entries.advanced(by: Int(index)).pointee
            if entry.signo == signo {
                let start = bytes.advanced(by: Int(entry.offset))
                let buffer = UnsafeBufferPointer(start: start, count: Int(entry.length))
                return Array(buffer)
            }
            index += 1
        }
        return nil
    }

    static func preparedPreviousSignalActionSlotCount() -> Int {
        preparePreviousSignalActionStorage()
        return Int(previousSignalActionCount)
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
        preparePreviousSignalActionStorage()
        guard let previousActions = previousSignalActionPointer else {
            return
        }

        for index in signalRecordDefinitions.indices {
            var previousAction = sigaction()
            _ = sigaction(signalRecordDefinitions[index].signo, nil, &previousAction)
            previousActions.advanced(by: index).pointee = previousAction
        }

        for index in signalRecordDefinitions.indices {
            let record = signalRecordDefinitions[index]
            var action = sigaction()
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            action.__sigaction_u.__sa_handler = signalHandler
            var previousAction = previousActions.advanced(by: index).pointee
            _ = sigaction(record.signo, &action, &previousAction)
            previousActions.advanced(by: index).pointee = previousAction
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

    private static func prepareSignalRecordStorage() {
        guard signalEntryPointer == nil, signalBytePointer == nil else {
            return
        }

        let renderedRecords = signalRecordDefinitions.map {
            Array(renderedSignalRecord(signo: $0.signo, name: $0.name).utf8)
        }
        let byteCount = renderedRecords.reduce(0) { $0 + $1.count }
        let entries = UnsafeMutablePointer<SignalEntry>.allocate(
            capacity: signalRecordDefinitions.count
        )
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)

        var offset = 0
        for index in signalRecordDefinitions.indices {
            let recordBytes = renderedRecords[index]
            let entry = signalRecordDefinitions[index]
            bytes.advanced(by: offset).initialize(from: recordBytes, count: recordBytes.count)
            entries.advanced(by: index).initialize(to: (
                signo: entry.signo,
                offset: Int32(offset),
                length: Int32(recordBytes.count)
            ))
            offset += recordBytes.count
        }

        signalBytePointer = bytes
        signalEntryPointer = entries
        signalEntryCount = Int32(signalRecordDefinitions.count)
    }

    private static func preparePreviousSignalActionStorage() {
        guard previousSignalActionPointer == nil else {
            return
        }

        let actions = UnsafeMutablePointer<sigaction>.allocate(
            capacity: signalRecordDefinitions.count
        )
        for index in signalRecordDefinitions.indices {
            actions.advanced(by: index).initialize(to: sigaction())
        }

        previousSignalActionPointer = actions
        previousSignalActionCount = Int32(signalRecordDefinitions.count)
    }
}
#endif
