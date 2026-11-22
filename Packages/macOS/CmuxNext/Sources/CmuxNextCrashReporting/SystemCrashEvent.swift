import Foundation
public import Sentry

/// A Sentry event for a helper process crash that macOS recorded (the
/// cmux-tui daemon and its terminal, app and browser hosts, acpmux, the
/// Chromium helpers). Frames carry instruction addresses and the debug
/// images their UUIDs, so Sentry symbolicates them from the debug files
/// the nightly uploads, as for the app's own crashes.
public nonisolated struct SystemCrashEvent: Sendable {
    public let report: SystemCrashReport

    public init(report: SystemCrashReport) {
        self.report = report
    }

    public func event() -> Event {
        let event = Event(level: .fatal)
        event.platform = "cocoa"
        var exceptions: [Exception] = []
        if !report.exceptionFrames.isEmpty {
            // The Objective-C throw stack goes first: Sentry lists the
            // oldest exception first and groups by the last one.
            let thrown = Exception(value: "uncaught exception", type: "NSException")
            thrown.mechanism = mechanism(type: "nsexception")
            thrown.stacktrace = stacktrace(report.exceptionFrames)
            exceptions.append(thrown)
        }
        let crash = Exception(value: [report.signal, report.termination].compactMap { $0 }.joined(separator: ", "),
                              type: report.exceptionType)
        crash.mechanism = mechanism(type: "mach")
        crash.stacktrace = stacktrace(report.frames)
        exceptions.append(crash)
        event.exceptions = exceptions
        event.debugMeta = report.images.filter { !$0.uuid.isEmpty }.map { image in
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = image.uuid
            meta.imageAddress = Self.hex(image.base)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.name
            return meta
        }
        event.tags = ["process": report.processName, "crash_source": "macos_crash_report"]
        if let incident = report.incident { event.extra = ["incident": incident] }
        return event
    }

    private func mechanism(type: String) -> Mechanism {
        let mechanism = Mechanism(type: type)
        mechanism.handled = false
        return mechanism
    }

    /// Sentry frames run outermost first; the report lists innermost first.
    private func stacktrace(_ frames: [SystemCrashReport.Frame]) -> SentryStacktrace {
        let sentryFrames: [Frame] = frames.reversed().compactMap { frame in
            guard report.images.indices.contains(frame.imageIndex) else { return nil }
            let image = report.images[frame.imageIndex]
            let out = Frame()
            out.instructionAddress = Self.hex(image.base &+ frame.imageOffset)
            out.imageAddress = Self.hex(image.base)
            out.package = image.name
            out.function = frame.symbol
            return out
        }
        return SentryStacktrace(frames: sentryFrames, registers: [:])
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }
}
