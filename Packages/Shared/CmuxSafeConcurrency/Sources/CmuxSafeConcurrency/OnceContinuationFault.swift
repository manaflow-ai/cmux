#if canImport(os)
internal import os
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

/// A misuse of a ``OnceContinuation`` that it survived: the task still resumed exactly once, but the
/// producer has a bug to fix.
public struct OnceContinuationFault: Sendable, Equatable {
    /// What went wrong.
    public enum Kind: Sendable, Equatable {
        /// A second resume, a no-op (a raw continuation stops the process here).
        case resumedTwice
        /// The continuation was dropped without a resume; the task resumed with
        /// ``OnceContinuationError/abandoned`` (a raw continuation leaks the task here).
        case abandoned
    }

    /// Where the wait was made: the caller of `withOnceContinuation`.
    public struct Site: Sendable, Equatable {
        public let function: String
        public let fileID: String
        public let line: Int
    }

    public let kind: Kind
    public let site: Site

    init(_ kind: Kind, at site: Site) {
        self.kind = kind
        self.site = site
    }

    /// One line for a log: the kind and the site.
    public var message: String {
        let what = switch kind {
        case .resumedTwice: "resumed twice; the second resume was ignored"
        case .abandoned: "dropped without a resume; the task resumed with OnceContinuationError.abandoned"
        }
        return "OnceContinuation made in \(site.function) at \(site.fileID):\(site.line) was \(what)"
    }
}

/// Where a ``OnceContinuation`` reports its faults: a seam the caller injects (tests record them; the app
/// can route them to its crash reporter). ``systemLog`` writes them to the unified log at fault level.
public struct OnceContinuationFaultReporter: Sendable {
    private let sink: @Sendable (OnceContinuationFault) -> Void

    /// A reporter that hands each fault to `sink`, on the thread that found it. Keep `sink` short and
    /// non-blocking: it runs inside a producer's resume or a deinit.
    public init(_ sink: @escaping @Sendable (OnceContinuationFault) -> Void) {
        self.sink = sink
    }

    /// Reports `fault`.
    public func report(_ fault: OnceContinuationFault) {
        sink(fault)
    }

    /// Writes each fault to the unified log at fault level (subsystem `com.cmuxterm.app.next`, category
    /// `OnceContinuation`), as the runtime reports a misused raw continuation; to standard error where there
    /// is no unified log.
    public static var systemLog: OnceContinuationFaultReporter {
        OnceContinuationFaultReporter { fault in
            #if canImport(os)
            Logger(subsystem: "com.cmuxterm.app.next", category: "OnceContinuation")
                .fault("\(fault.message, privacy: .public)")
            #else
            var line = fault.message + "\n"
            line.withUTF8 { bytes in
                // SAFETY: `bytes` is the string's own contiguous UTF-8 storage, valid for `count` bytes for the
                // whole closure, and write(2) only reads it.
                _ = unsafe write(2, bytes.baseAddress, bytes.count)
            }
            #endif
        }
    }
}
