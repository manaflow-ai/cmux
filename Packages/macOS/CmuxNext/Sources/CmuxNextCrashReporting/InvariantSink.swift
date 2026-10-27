public import CmuxNextWakeups
public import CmuxSafeConcurrency
public import Foundation
public import Sentry

/// The app's ``InvariantEventSink`` (p10-stability-099): the first failure of each
/// `Invariant.notFatalUntil` / `Invariant.dumpWillBeCheck` site and the first call of each
/// `Invariant.dumpWithoutCrashing` site (p09-observability-130) in a launch becomes one Sentry event, built
/// and sent on the crash-reporting lane, never on the thread that failed.
///
/// On the caller's thread ``deliver(_:)`` reads one stored flag, takes the stack's return addresses
/// (a frame-pointer walk: no I/O, no lock), reads the crash keys (``InvariantCrashKeys``: relaxed loads) and
/// enqueues one block on the lane. Debug images (dladdr), the
/// event and the Sentry call happen on the lane. Consent is this launch's: with crash reporting off
/// (consent, managed policy, DEV build without `CMUX_NEXT_DEV_SENTRY=1`, tests) nothing is enqueued, and the
/// lane checks it again before it sends.
///
/// ```swift
/// InvariantSink.install(reporter: reporter, bundleVersion: info["CFBundleVersion"] as? String, crashKeys: keys)
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
    private let crashKeys: CrashKeySlots?

    /// Sends through `reporter` on its own utility queue, when `reporter` runs this launch, with the crash keys
    /// of `crashKeys` (none when nil).
    public convenience init(reporter: CrashReporter, crashKeys: CrashKeySlots? = nil) {
        let queue = DispatchQueue(label: "com.cmuxterm.app.next.invariant-sink", qos: .utility)
        self.init(sends: reporter.isStarted, lane: { queue.async(execute: $0) },
                  capture: { reporter.reportInvariant($0) }, crashKeys: crashKeys)
    }

    /// Test seam: whether it sends, the lane, the capture, the stack walk and the crash keys.
    public init(sends: Bool, lane: @escaping Lane, capture: @escaping Capture,
                stack: @escaping @Sendable () -> [UInt] = { Thread.callStackReturnAddresses.map(\.uintValue) },
                crashKeys: CrashKeySlots? = nil) {
        self.sends = sends
        self.lane = lane
        self.capture = capture
        self.stack = stack
        self.crashKeys = crashKeys
    }

    /// Installs this launch's running build and a sink for `reporter` into `invariant` (the process's by
    /// default). Call once from the composition root, after `reporter.start`, so the sink sees its consent.
    ///
    /// - Parameter crashKeys: The app's crash keys, read into each event (``InvariantCrashKeys``).
    /// - Returns: Whether they were installed; false when the invariant already had an installation.
    @discardableResult
    public static func install(reporter: CrashReporter, bundleVersion: String?, crashKeys: CrashKeySlots? = nil,
                               into invariant: Invariant = .process) -> Bool {
        invariant.install(build: runningBuild(bundleVersion: bundleVersion),
                          sink: InvariantSink(reporter: reporter, crashKeys: crashKeys))
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
        let keys = crashKeys.map { InvariantCrashKeys($0) }
        let capture = self.capture
        lane { capture(Self.event(for: event, addresses: addresses, crashKeys: keys)) }
    }

    /// The Sentry event of `failure`, grouped by its site (not its stack), tagged with `crashKeys`. Resolves
    /// debug images (dladdr): call on the lane.
    static func event(for failure: InvariantEvent, addresses: [UInt], crashKeys: InvariantCrashKeys? = nil) -> Event {
        let (level, tier, type): (SentryLevel, String, String) = switch failure.kind {
        case .notFatalUntil: (.error, "not_fatal_until", "InvariantFailure")
        case .dumpWillBeCheck: (.warning, "dump_will_be_check", "InvariantFailure")
        case .dumpWithoutCrashing: (.warning, "dump_without_crashing", "DumpWithoutCrashing")
        }
        let id = failure.id.description
        let event = Event(level: level)
        event.platform = "cocoa"
        let exception = Exception(value: failure.message, type: type)
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
        var tags = crashKeys?.tags ?? [:]
        tags["invariant_id"] = id
        tags["invariant_tier"] = tier
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
