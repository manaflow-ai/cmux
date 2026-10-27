import Foundation
public import Sentry

/// A crash-reporting event for a finished main-thread lag spike (a stall
/// shorter than a hang, for example 250 ms to 2 s): the main thread's stack
/// sampled during the stall as raw return addresses with their debug
/// images, so the server symbolicates and groups it by stack.
///
/// Warning level: one spike is a dropped-frames bug, not a failure. The
/// exception value names a duration bucket, never the exact time, so
/// grouping depends only on the stack.
public nonisolated struct LagSpikeEvent: Sendable {
    public let duration: Duration
    /// Main-thread CPU time during the stall: near ``duration`` for app
    /// work, much lower for a blocking wait.
    public let cpu: Duration
    /// Return addresses, innermost first; empty when sampling failed.
    public let addresses: [UInt]
    /// Counts and states that describe the app at the spike (window count,
    /// for example). Values must hold no user content.
    public let context: [String: String]
    /// The stall's sample caught the main thread inside the Chromium message pump (the stall record's `cef`):
    /// the `hang.cef` tag (`true`); false sets no tag.
    public let cef: Bool

    public init(duration: Duration, cpu: Duration, addresses: [UInt], context: [String: String] = [:], cef: Bool = false) {
        self.duration = duration
        self.cpu = cpu
        self.addresses = addresses
        self.context = context
        self.cef = cef
    }

    /// The duration bucket: `250-500ms`, `500ms-1s`, `1-2s` or `2s+`.
    public var bucket: String {
        let ms = Int(duration / .milliseconds(1))
        switch ms {
        case ..<500: return "250-500ms"
        case ..<1_000: return "500ms-1s"
        case ..<2_000: return "1-2s"
        default: return "2s+"
        }
    }

    /// Whether the main thread mostly waited (CPU under a third of the wall time).
    public var mostlyBlocked: Bool { cpu * 3 < duration }

    /// Builds the event. Resolves debug images (dladdr): call off the main thread.
    public func event() -> Event {
        let event = Event(level: .warning)
        event.platform = "cocoa"
        let stall = Exception(value: "main thread stalled \(bucket)", type: "MainThreadStall")
        let mechanism = Mechanism(type: "main_thread_watchdog")
        mechanism.handled = true
        stall.mechanism = mechanism
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
        if !frames.isEmpty { stall.stacktrace = SentryStacktrace(frames: frames, registers: [:]) }
        event.exceptions = [stall]
        event.debugMeta = images.map { image in
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = image.uuid
            meta.imageAddress = MainThreadHangEvent.hex(image.base)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.path
            return meta
        }
        event.tags = [
            "hang_source": "main_thread_stall",
            "stall_bucket": bucket,
            "stall_blocked": mostlyBlocked ? "yes" : "no",
        ]
        if cef { event.tags?["hang.cef"] = "true" }
        var extra: [String: Any] = [
            "stall_ms": Int(duration / .milliseconds(1)),
            "cpu_ms": Int(cpu / .milliseconds(1)),
            "frames": addresses.count,
        ]
        for (key, value) in context { extra[key] = value }
        event.extra = extra
        // A spike with no stack has nothing to group by: one issue per bucket.
        if frames.isEmpty { event.fingerprint = ["main_thread_stall", "no_stack", bucket] }
        return event
    }
}
