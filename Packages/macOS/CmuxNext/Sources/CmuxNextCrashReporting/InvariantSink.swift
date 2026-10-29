public import CmuxSafeConcurrency
public import Foundation
public import Sentry

/// The app's ``InvariantEventSink``: the first failure of each
/// `Invariant.notFatalUntil` / `Invariant.dumpWillBeCheck` site in a launch becomes one Sentry event, built
/// and sent on the crash-reporting lane, never on the thread that failed.
///
/// On the caller's thread ``deliver(_:)`` reads one stored flag, takes the stack's return addresses
/// (a frame-pointer walk: no I/O, no lock) and enqueues one block on the lane. Debug images (dladdr), the
/// event and the Sentry call happen on the lane. Consent is this launch's: with crash reporting off
/// (consent, managed policy, DEV build without `CMUX_NEXT_DEV_SENTRY=1`, tests) nothing is enqueued, and the
/// lane checks it again before it sends.
///
/// ```swift
/// InvariantSink.install(reporter: reporter, bundleVersion: info["CFBundleVersion"] as? String)
/// ```
public final class InvariantSink: InvariantEventSink {
    /// Runs one block off the caller's thread, in order.
    public typealias Lane = @Sendable (@escaping @Sendable () -> Void) -> Void
    /// Sends one built event.
    public typealias Capture = @Sendable (Event) -> Void

    private let sends: Bool
    private let lane: Lane
    private let capture: Capture
    private let stack: @Sendable () -> [UInt]

    /// Sends through `reporter` on its own utility queue, when `reporter` runs this launch.
    public convenience init(reporter: CrashReporter) {
        let queue = DispatchQueue(label: "com.cmuxterm.app.next.invariant-sink", qos: .utility)
        self.init(sends: reporter.isStarted, lane: { queue.async(execute: $0) },
                  capture: { reporter.reportInvariant($0) })
    }

    /// Test seam: whether it sends, the lane, the capture and the stack walk.
    public init(sends: Bool, lane: @escaping Lane, capture: @escaping Capture,
                stack: @escaping @Sendable () -> [UInt] = { Thread.callStackReturnAddresses.map(\.uintValue) }) {
        self.sends = sends
        self.lane = lane
        self.capture = capture
        self.stack = stack
    }

    /// Installs this launch's running build and a sink for `reporter` into `invariant` (the process's by
    /// default). Call once from the composition root, after `reporter.start`, so the sink sees its consent.
    ///
    /// - Returns: Whether they were installed; false when the invariant already had an installation.
    @discardableResult
    public static func install(reporter: CrashReporter, bundleVersion: String?,
                               into invariant: Invariant = .process) -> Bool {
        invariant.install(build: runningBuild(bundleVersion: bundleVersion), sink: InvariantSink(reporter: reporter))
    }

    /// The running build `Invariant.notFatalUntil` compares with: `CFBundleVersion` when it is a whole number
    /// (nightly and release builds), else nil (a build that never traps a notFatalUntil site).
    public static func runningBuild(bundleVersion: String?) -> UInt64? {
        guard let text = bundleVersion?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return UInt64(text, radix: 10)
    }

    public func deliver(_ event: InvariantEvent) {
        guard sends else { return }
        let addresses = stack()
        let capture = self.capture
        lane { capture(Self.event(for: event, addresses: addresses)) }
    }

    /// The Sentry event of `failure`, grouped by its site (not its stack). Resolves debug images (dladdr):
    /// call on the lane.
    static func event(for failure: InvariantEvent, addresses: [UInt]) -> Event {
        let level: SentryLevel
        let tier: String
        switch failure.kind {
        case .notFatalUntil:
            level = .error
            tier = "not_fatal_until"
        case .dumpWillBeCheck:
            level = .warning
            tier = "dump_will_be_check"
        }
        let id = failure.id.description
        let event = Event(level: level)
        event.platform = "cocoa"
        let exception = Exception(value: failure.message, type: "InvariantFailure")
        let mechanism = Mechanism(type: "cmux_invariant")
        mechanism.handled = true
        exception.mechanism = mechanism
        let images = MainThreadHangEvent.images(for: addresses)
        let frames: [Frame] = addresses.reversed().map { address in
            let frame = Frame()
            frame.instructionAddress = MainThreadHangEvent.hex(UInt64(address))
            if let image = images.first(where: { $0.contains(address) }) {
                frame.imageAddress = MainThreadHangEvent.hex(image.base)
                frame.package = image.path
            }
            return frame
        }
        if !frames.isEmpty { exception.stacktrace = SentryStacktrace(frames: frames, registers: [:]) }
        event.exceptions = [exception]
        event.message = SentryMessage(formatted: failure.message)
        event.debugMeta = images.map { image in
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = image.uuid
            meta.imageAddress = MainThreadHangEvent.hex(image.base)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.path
            return meta
        }
        var tags = ["invariant_id": id, "invariant_tier": tier]
        if case .notFatalUntil(let build) = failure.kind { tags["invariant_fatal_build"] = String(build) }
        event.tags = tags
        event.fingerprint = ["invariant", id, failure.site]
        return event
    }
}

extension CrashReporter {
    /// Sends an invariant failure's event. Call on the crash-reporting lane; does nothing when crash reporting
    /// is off.
    public nonisolated func reportInvariant(_ event: Event) {
        guard isStarted else { return }
        SentrySDK.capture(event: event)
    }
}
