import Foundation
public import Sentry

/// A crash-reporting event for a watched thread still inside its hang-watch scope 2 s past its budget
/// (``CrashReporter/reportThreadHang(_:)``, p09-observability-068): the hung thread's stack as raw return
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
    /// Who found the hang: the `hang_source` tag. ``hangWatchSource`` for cmux's hang watch, ``chromiumSource`` for
    /// Chromium's own HangWatcher in the browser process (p09-observability-106).
    public let source: String
    /// The other threads the same capture found hung, most severe first: the `hung_threads` extra, so one capture is
    /// one event however many threads it names (Chrome's `HangWatcher::RecordHang` dumps once, every id in one crash key).
    public let alsoHung: [String]

    /// cmux's hang watch (the main-thread watchdog's monitor).
    public static let hangWatchSource = "hang_watch"
    /// Chromium's HangWatcher (base/threading/hang_watcher.cc), through the fork's dump handler.
    public static let chromiumSource = "chromium"

    /// Makes the value from its parts.
    public init(thread: String, threadKind: String, threadName: String, overrun: Duration, addresses: [UInt],
                source: String = ThreadHangEvent.hangWatchSource, alsoHung: [String] = []) {
        self.thread = thread
        self.threadKind = threadKind
        self.threadName = threadName
        self.overrun = overrun
        self.addresses = addresses
        self.source = source
        self.alsoHung = alsoHung
    }

    /// The Sentry event: one exception with the hung thread's stack, that thread (crashed, so Sentry shows its
    /// stack first), the debug images, and the `hang_source` (``source``), `hang.thread` and `hang.thread_kind` tags.
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
        event.tags = ["hang_source": source, "hang.thread": thread, "hang.thread_kind": threadKind]
        event.extra = ["hang_overrun_ms": overrunMs]
        if !threadName.isEmpty { event.extra?["thread_name"] = threadName }
        if !alsoHung.isEmpty { event.extra?["hung_threads"] = alsoHung }
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
