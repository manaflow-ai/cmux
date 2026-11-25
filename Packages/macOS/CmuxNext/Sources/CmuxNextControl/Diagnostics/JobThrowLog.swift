import Foundation
import os

/// The newest ``JobThrow``s of the process, and the report that names the one that left a Swift
/// executor record dead (#44060, #44185).
///
/// A value: its owner keeps it where the exception preprocessor can reach it (the app keeps it in
/// its uncaught-exception recorder's state) and calls ``note(_:)`` there.
///
/// ```swift
/// var log = JobThrowLog()
/// if let thrown = JobThrow.capture(exception) { log.note(thrown) }
/// let candidates = log.candidates(at: deadRecord)
/// ```
public struct JobThrowLog: Sendable {
    /// Throws kept; older ones are dropped.
    public static let limit = 8

    private var kept: [JobThrow] = []

    /// An empty log.
    public init() {}

    /// Keeps `jobThrow`, dropping the oldest beyond ``limit``.
    public mutating func note(_ jobThrow: JobThrow) {
        kept.append(jobThrow)
        if kept.count > Self.limit { kept.removeFirst(kept.count - Self.limit) }
    }

    /// The kept throws whose job ran at `record`, newest first: the candidates for the throw that
    /// left `record` dead.
    public func candidates(at record: UInt) -> [JobThrow] {
        kept.filter { $0.record == record }.reversed()
    }

    /// The names of all kept throws, oldest first.
    public var names: [String] { kept.map(\.name) }

    /// Logs that the executor record `dead` was found dead and cleared, as a fault (subsystem
    /// `com.cmuxterm.app.next`, category `crash`) naming the newest throw kept at it, and passes the
    /// same to `send` (a handled crash-report event). Symbolicates off the main thread.
    ///
    /// - Parameters:
    ///   - dead: The dead record's address.
    ///   - send: Gets a one-line message, the exception's name ("none" when no throw was kept) and the
    ///     symbolicated throw.
    public func reportLost(_ dead: UInt, send: (@Sendable (String, String, String) -> Void)?) {
        let newest = candidates(at: dead).first
        let now = ProcessInfo.processInfo.systemUptime
        let address = "0x" + String(dead, radix: 16)
        // task-owner: fire and forget; holds only values and ends after one log write and one send.
        Task.detached(priority: .utility) {
            let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
            guard let newest else {
                logger.fault("Swift executor record \(address, privacy: .public) was dead at sendEvent; no Objective-C throw inside a main-thread Swift job was kept at that record (#44060)")
                send?("Swift executor record lost: no throw kept", "none", "")
                return
            }
            let text = newest.describe(now: now)
            logger.fault("Swift executor record \(address, privacy: .public) was dead at sendEvent; the newest Objective-C throw inside a main-thread Swift job at that record (#44060): \(text, privacy: .public)")
            send?("Swift executor record lost after \(newest.name): \(newest.reason.prefix(120))", newest.name, text)
        }
    }
}
