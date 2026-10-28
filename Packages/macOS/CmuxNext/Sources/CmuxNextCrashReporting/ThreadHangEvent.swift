import Foundation
public import Sentry

/// A crash-reporting event for a watched thread still inside its hang-watch scope 2 s past its budget
/// (``CrashReporter/reportThreadHang(_:)``): the hung thread's stack as raw return
/// addresses with the debug images that hold them, symbolicated on the server as a main-thread hang is
/// (``MainThreadHangEvent``). It is Chrome's `HangWatcher::RecordHang`, which dumps without crashing and
/// names the hung thread (base/threading/hang_watcher.cc); the `hang.thread` tag names it here.
public nonisolated struct ThreadHangEvent: Sendable, Equatable {
    /// The registration's catalog name (`daemon-reader`, `terminal-output`): the `hang.thread` tag.
    public let thread: String
    /// What the registered thread runs (`io`, `lane`, `renderer`, ...): the `hang.thread_kind` tag.
    public let threadKind: String
    /// The kernel's name of the thread that ran the scope (a lane's job runs on a pool thread); empty when unnamed.
    public let threadName: String
    /// How far past its budget the scope was when its stack was sampled.
    public let overrun: Duration
    /// Return addresses, innermost first (the monitor's sample of the hung thread).
    public let addresses: [UInt]

    /// Makes the value from its parts.
    public init(thread: String, threadKind: String, threadName: String, overrun: Duration, addresses: [UInt]) {
        self.thread = thread
        self.threadKind = threadKind
        self.threadName = threadName
        self.overrun = overrun
        self.addresses = addresses
    }

    /// The Sentry event: one exception with the hung thread's stack, that thread (crashed, so Sentry shows its
    /// stack first), the debug images, and the `hang_source`, `hang.thread` and `hang.thread_kind` tags.
    public func event() -> Event {
        let event = Event(level: .error)
        event.platform = "cocoa"
        let overrunMs = Int(overrun / .milliseconds(1))
        let hang = Exception(value: "\(thread) busy \(overrunMs) ms past its budget and counting", type: "ThreadHang")
        let mechanism = Mechanism(type: "hang_watch")
        mechanism.handled = true
        hang.mechanism = mechanism
        let images = MainThreadHangEvent.images(for: addresses)
        let stacktrace = MainThreadHangEvent.stacktrace(addresses, images: images, packages: true)
        hang.stacktrace = stacktrace
        hang.threadId = NSNumber(value: 0)
        let hung = SentryThread(threadId: NSNumber(value: 0))
        hung.name = threadName.isEmpty ? thread : threadName
        hung.isMain = NSNumber(value: threadKind == "main")
        hung.current = NSNumber(value: true)
        hung.crashed = NSNumber(value: true)
        hung.stacktrace = stacktrace
        event.exceptions = [hang]
        event.threads = [hung]
        event.debugMeta = MainThreadHangEvent.debugMeta(images)
        event.tags = ["hang_source": "hang_watch", "hang.thread": thread, "hang.thread_kind": threadKind]
        event.extra = ["hang_overrun_ms": overrunMs]
        if !threadName.isEmpty { event.extra?["thread_name"] = threadName }
        return event
    }
}

extension CrashReporter {
    /// Sends a watched thread's hang that is still running (the main-thread watchdog's thread calls this, at most
    /// once per registration name and report interval). Does nothing when crash reporting is off.
    public nonisolated func reportThreadHang(_ hang: ThreadHangEvent) {
        guard isStarted else { return }
        SentrySDK.capture(event: hang.event())
    }
}
