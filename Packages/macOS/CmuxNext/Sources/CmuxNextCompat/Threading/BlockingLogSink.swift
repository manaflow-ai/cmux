import os

/// Records each new main-thread blocking call site in the unified log and continues: the sink of
/// builds that ship with the detector (Nightly, `-DCMUX_BLOCKING_CHECKS`) and of bench and Debug builds.
///
/// One line per call site per launch (category `blocking`, error level, so it stays in the log store and
/// in a sysdiagnose): the kind and the stack as image UUID + offset frames only, the same fields a
/// ``BlockingViolation`` carries, so the line is public and names no path, file, symbol or user text.
/// Symbolicate a frame with the image's dSYM (`atos -o <dSYM> -l 0 <offset>` after matching the UUID).
/// It never traps; the detector's mode decides that.
///
/// ```swift
/// blocking.install(sink: BlockingLogSink())   // AppServices, the composition root
/// ```
///
/// Tests pass a `write` that records the line.
public final class BlockingLogSink: BlockingViolationSink {
    private let write: @Sendable (String) -> Void

    /// - Parameter write: Where each line goes; the default is the unified log (subsystem
    ///   `com.cmuxterm.app.next`, category `blocking`).
    public init(write: (@Sendable (String) -> Void)? = nil) {
        self.write = write ?? { line in
            Logger(subsystem: "com.cmuxterm.app.next", category: "blocking").error("\(line, privacy: .public)")
        }
    }

    /// Writes one line for `violation` (on the detector's drain queue).
    public func record(_ violation: BlockingViolation) {
        write(Self.line(violation))
    }

    /// The line for `violation`: `blocking <kind> on the main thread; frames <uuid>+0x<offset> ...`.
    public static func line(_ violation: BlockingViolation) -> String {
        let frames = violation.frames.map { "\($0.imageUUID.uuidString)+0x\(String($0.offset, radix: 16))" }
        return "blocking \(violation.kind.rawValue) on the main thread; frames "
            + (frames.isEmpty ? "none" : frames.joined(separator: " "))
    }
}
