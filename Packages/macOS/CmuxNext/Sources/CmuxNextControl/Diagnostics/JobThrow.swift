import CmuxNextActions
import Darwin
public import Foundation

/// An Objective-C exception thrown on the main thread while a Swift job ran there (#44060, #44185).
///
/// Such a throw that is caught outside the job (by an older system frame) unwinds the job's frame
/// and leaves the runtime's executor record dead. `sendEvent:` finds the dead record later; the
/// throws kept at that record (``JobThrowLog``) name which exception did it.
public struct JobThrow: Equatable, Sendable {
    /// The executor record of the job that ran when the exception was thrown.
    public var record: UInt
    /// The exception's name, as `NSRangeException`.
    public var name: String
    /// The first line of the exception's reason, at most 300 characters.
    public var reason: String
    /// The throwing thread's return addresses at the throw, innermost first.
    public var addresses: [UInt]
    /// Seconds since boot at the throw (`ProcessInfo.systemUptime`).
    public var uptime: TimeInterval

    /// A throw with the given parts; ``capture(_:)`` makes one at a real throw.
    public init(record: UInt, name: String, reason: String, addresses: [UInt], uptime: TimeInterval) {
        self.record = record
        self.name = name
        self.reason = reason
        self.addresses = addresses
        self.uptime = uptime
    }

    /// The throw of `exception` now, when the calling thread is the main thread and runs a Swift
    /// job; nil otherwise (a throw where no job runs cannot leave a record dead). Called from an
    /// exception preprocessor, before the throw unwinds.
    public static func capture(_ exception: AnyObject) -> JobThrow? {
        guard pthread_main_np() != 0, let record = SwiftExecutorFrames.activeRecord(),
              let exception = exception as? NSException else { return nil }
        let reason = (exception.reason ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return JobThrow(record: record, name: exception.name.rawValue, reason: String(reason.prefix(300)),
                        addresses: Thread.callStackReturnAddresses.map(\.uintValue),
                        uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// "name: reason (N s before)", then the throw's frames named through the app symbol map.
    /// Symbolicates: call off the main thread.
    public func describe(now: TimeInterval, frameLimit: Int = 32) -> String {
        let frames = StackSymbolicator().frames(for: Array(addresses.prefix(frameLimit))).map(\.description)
        let age = String(format: "%.1f", max(0, now - uptime))
        return "\(name): \(reason) (\(age) s before)\n" + frames.joined(separator: "\n")
    }
}
