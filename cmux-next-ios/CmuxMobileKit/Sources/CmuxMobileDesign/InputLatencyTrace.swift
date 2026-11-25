#if os(iOS) && DEBUG
import Darwin
import Foundation
import Observation
import OSLog
import QuartzCore
import SwiftUI
import UIKit

/// Input responsiveness on the phone, measured from inside the app (DEBUG only,
/// `CMUX_MOBILE_INPUT_LATENCY=1` or `-cmux-mobile-input-latency`;
/// `cmux-next-ios/design/input-latency.md`, `InputLatencyUITests`):
///
/// - every main-thread run-loop iteration of 4 ms or more, with the main
///   thread's stack sampled every 4 ms while it runs (a watchdog thread
///   suspends main, walks its frame pointers into a preallocated buffer and
///   resumes it; symbols are read afterwards, off the main thread);
/// - the keyboard windows: from each will-show and will-hide notification,
///   the main thread's longest iteration, its iterations of 4 ms and more, and
///   `free_ms`, the time until the last such iteration in the window ended
///   (after it a touch is handled in the frame it lands in);
/// - latency samples the app reports (`sample`): keystroke to echo
///   presented, send tap to the message drawn, send tap to the host's ack.
///
/// Every hitch, window and sample is a JSON line in
/// `Documents/input-latency.jsonl` and a signpost (`dev.cmux.mobile`,
/// category `input`); the counts so far are one JSON object in a nearly
/// transparent label, `debug.input-latency`, which the UI test reads.
///
/// Cost is bounded: off, nothing runs; on, one run-loop observer, one
/// watchdog thread waking every millisecond, 16 stacks per iteration at most,
/// and the last 512 samples per kind for the board.
@MainActor
public final class InputLatencyTrace {
    public nonisolated static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["CMUX_MOBILE_INPUT_LATENCY"] == "1"
            || CommandLine.arguments.contains("-cmux-mobile-input-latency")

    /// Separate attribution run. The ordinary settle run keeps its 4 ms hitch sampler.
    public nonisolated static let samplesTouches = CommandLine.arguments.contains("-cmux-mobile-input-touch-stacks")

    public static let shared: InputLatencyTrace? = isEnabled ? InputLatencyTrace() : nil

    static let signposter = OSSignposter(subsystem: "dev.cmux.mobile", category: "input")
    public static let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("input-latency.jsonl")

    /// Iterations at or over this are recorded (ms).
    static let recordMs = 4.0
    /// How long a keyboard window stays open past the animation's duration (s).
    static let windowTail = 0.3

    private let watch: MainThreadWatch
    /// Appends lines to the file, and does nothing else, so a line is written as soon as it is
    /// made. Slow work (symbolizing a hitch's stacks, a touch's 0.45 s stack sampling) runs on
    /// `symbolizer` and hands its finished line here: when the two shared one serial utility
    /// queue, a burst of hitches under duress=heavy queued every key sample behind seconds of
    /// dladdr, and a run's trace came out with none (or part) of its keys.
    nonisolated private let writer = DispatchQueue(label: "dev.cmux.mobile.input-latency", qos: .userInitiated)
    private let symbolizer = DispatchQueue(label: "dev.cmux.mobile.input-latency.symbols",
                                           qos: InputLatencyTrace.samplesTouches ? .userInitiated : .utility)
    nonisolated private let handle: FileHandle?
    private var observer: CFRunLoopObserver?
    private var observers: [NSObjectProtocol] = []

    /// Open keyboard windows (one per notification, closed after its tail).
    private var windows: [KeyboardWindow] = []
    /// Samples per kind (ms), the last 512 each.
    private var samples: [String: [Double]] = [:]
    /// Hitches (iterations of 8 ms and more) and iterations of 4 ms and more, in all.
    private var hitches8 = 0
    private var iterations4 = 0
    private var maxIterationMs = 0.0
    /// Keystroke-to-glyph intervals open per kind (`beginKey`), closed by that kind's `sample`.
    private var keyIntervals: [String: OSSignpostIntervalState] = [:]
    /// The typing window: from a key typed in a composer until `typingTail`
    /// after the last one. Its own hitch counts are what typing feels
    /// (`ComposerLinkUITests`), apart from the scrolls and loads around it.
    static let typingTail = 0.5
    private var typingStart: CFTimeInterval?
    private var typingUntil: CFTimeInterval = 0
    private var typingHitches8 = 0
    private var typingIterations4 = 0
    private var typingMaxMs = 0.0
    private var typingKeys = 0
    /// Work counted while typing (`note`): draft files written on the main
    /// thread, transcript scans, composer re-renders.
    private var typingNotes: [String: Int] = [:]

    private init() {
        let url = Self.fileURL
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        watch = MainThreadWatch()
        if Self.samplesTouches { return }
        installRunLoopObserver()
        installKeyboardObservers()
        watch.start()
        InputLatencyBoard.shared?.update(summary)
    }

    /// Starts the trace when it is switched on (call once, early, on main).
    public static func startIfRequested() { _ = shared }

    /// The pin trace calls this at finger-down. Capture through release and the
    /// first frame, including short run-loop iterations. Store the actual sample
    /// times and the time spent reading main so offline attribution can account
    /// for cadence and sampler overhead. Symbolication happens after the burst.
    public func sampleTouch() {
        let began = CACurrentMediaTime()
        let watch = watch
        symbolizer.async { [weak self] in
            var observations: [(start: Double, end: Double, frames: [UInt])] = []
            while CACurrentMediaTime() < began + 0.45 {
                let start = CACurrentMediaTime()
                let frames = watch.sample()
                observations.append((start, CACurrentMediaTime(), frames))
                usleep(150)
            }
            var frameIDs: [UInt: Int] = [:]
            var symbols: [String] = []
            let samples: [[Int]] = observations.map { observation in
                let startUS = Int(((observation.start - began) * 1e6).rounded())
                let endUS = Int(((observation.end - began) * 1e6).rounded())
                return [startUS, endUS] + observation.frames.map { address in
                    if let id = frameIDs[address] { return id }
                    let id = symbols.count
                    frameIDs[address] = id
                    symbols.append(Self.symbol(for: address))
                    return id
                }
            }
            let record: [String: Any] = ["type": "touch-stacks", "start": began,
                                         "symbols": symbols, "samples": samples]
            if let data = try? JSONSerialization.data(withJSONObject: record) {
                let line = String(decoding: data, as: UTF8.self)
                self?.writer.async { [weak self] in self?.writeNow(line) }
            }
        }
    }

    // MARK: Samples the app reports

    /// A keystroke left: opens a `key_to_glyph` signpost interval for `kind`, closed when
    /// `kind`'s sample comes (the glyph drawn), so Instruments shows each keystroke to its glyph.
    public func beginKey(_ kind: String) {
        if let open = keyIntervals.removeValue(forKey: kind) { Self.signposter.endInterval("key_to_glyph", open, "superseded") }
        keyIntervals[kind] = Self.signposter.beginInterval("key_to_glyph", id: Self.signposter.makeSignpostID(), "\(kind, privacy: .public)")
    }

    /// A latency sample of `kind` (ms), e.g. `terminal_key_echo`, `chat_send_visible`.
    public func sample(_ kind: String, ms: Double) {
        if let open = keyIntervals.removeValue(forKey: kind) {
            Self.signposter.endInterval("key_to_glyph", open, "\(ms, format: .fixed(precision: 1))ms")
        }
        var list = samples[kind, default: []]
        list.append(ms)
        if list.count > 512 { list.removeFirst(list.count - 512) }
        samples[kind] = list
        Self.signposter.emitEvent("sample", "\(kind, privacy: .public) \(ms, format: .fixed(precision: 1))ms")
        write(#"{"type":"sample","kind":"\#(kind)","ms":\#(Self.f(ms)),"t":\#(Self.f(CACurrentMediaTime() * 1000))}"#)
        InputLatencyBoard.shared?.update(summary)
    }

    /// A sample from `start` (`CACurrentMediaTime`) to now.
    public func sample(_ kind: String, since start: CFTimeInterval) {
        sample(kind, ms: (CACurrentMediaTime() - start) * 1000)
    }

    /// A sample from `start` to the next frame presented (the frame that
    /// draws what was just laid out).
    public func sampleAtNextFrame(_ kind: String, since start: CFTimeInterval) {
        NextFrame.after { [weak self] in self?.sample(kind, since: start) }
    }

    /// A sample from `start` to the end of this run-loop pass's Core Animation
    /// commit: the keystroke's work done and its frame handed to the render
    /// server (`<field>_key_commit`). Unlike `sampleAtNextFrame` it does not
    /// include the wait for the next vsync (up to a frame at 60 Hz, Low Power
    /// Mode's rate), so it says what the app itself spent on the key.
    public func sampleAfterCommit(_ kind: String, since start: CFTimeInterval) {
        // Core Animation commits at order 2_000_000 before the run loop waits.
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          false, 2_000_001) { _, _ in
            MainActor.assumeIsolated { InputLatencyTrace.shared?.sample(kind, since: start) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Runs `action` at the next frame (a count read after the frame's layout).
    public func atNextFrame(_ action: @escaping @MainActor () -> Void) {
        NextFrame.after(action)
    }

    /// Runs `action` once, after this run-loop pass's Core Animation commit.
    public func afterCommit(_ action: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          false, 2_000_001) { _, _ in
            MainActor.assumeIsolated { action() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Counts of events (a view body built, a size asked), read per key as deltas
    /// (`<field>_key_<name>`); counting writes nothing.
    public private(set) var counters: [String: Int] = [:]

    public func count(_ name: String) { counters[name, default: 0] += 1 }

    /// The calling thread's CPU time (ms): the main thread's work per key, which a busy host
    /// stretches far less than wall time.
    public nonisolated static func threadCPUms() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
    }

    // MARK: Run loop

    private func installRunLoopObserver() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue
        let watch = watch
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                watch.begin(at: now)
            } else if let ended = watch.end(at: now) {
                MainActor.assumeIsolated { InputLatencyTrace.shared?.iterationEnded(ended) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func iterationEnded(_ iteration: MainThreadWatch.Iteration) {
        let ms = (iteration.end - iteration.start) * 1000
        guard ms >= Self.recordMs else { return }
        iterations4 += 1
        if ms >= 8 { hitches8 += 1 }
        maxIterationMs = max(maxIterationMs, ms)
        if let typingStart, iteration.end >= typingStart, iteration.start <= typingUntil {
            typingIterations4 += 1
            if ms >= 8 { typingHitches8 += 1 }
            typingMaxMs = max(typingMaxMs, ms)
        }
        let labels = windows.filter { $0.contains(iteration.start) || $0.contains(iteration.end) }
        for index in windows.indices where windows[index].contains(iteration.start) || windows[index].contains(iteration.end) {
            windows[index].add(iteration)
        }
        let label = labels.map(\.name).joined(separator: ",")
        let start = iteration.start
        let stacks = iteration.stacks
        Self.signposter.emitEvent("hitch", "\(ms, format: .fixed(precision: 1))ms \(label, privacy: .public)")
        symbolizer.async { [weak self] in
            let symbols = stacks.map { $0.map(Self.symbol(for:)) }
            let body = symbols.map { "[" + $0.map(Self.quoted).joined(separator: ",") + "]" }.joined(separator: ",")
            let line = #"{"type":"hitch","ms":\#(Self.f(ms)),"t":\#(Self.f(start * 1000)),"window":"\#(label)","samples":\#(stacks.count),"stacks":[\#(body)]}"#
            self?.writer.async { [weak self] in self?.writeNow(line) }
        }
        InputLatencyBoard.shared?.update(summary)
    }

    // MARK: Typing window

    /// A key typed in a composer: opens the typing window or extends it.
    public func typed() {
        let now = CACurrentMediaTime()
        if typingStart == nil { typingStart = watch.currentStart ?? now }
        typingUntil = now + Self.typingTail
        typingKeys += 1
    }

    /// One piece of `kind` work on the main thread; counted while typing.
    public func note(_ kind: String) {
        guard typingStart != nil, CACurrentMediaTime() <= typingUntil else { return }
        typingNotes[kind, default: 0] += 1
        // Never from inside a view update (a body notes its own render): on the next turn.
        guard !boardPending else { return }
        boardPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.boardPending = false
            InputLatencyBoard.shared?.update(self.summary)
        }
    }
    private var boardPending = false

    // MARK: Keyboard windows

    private func installKeyboardObservers() {
        let center = NotificationCenter.default
        for (name, label) in [(UIResponder.keyboardWillShowNotification, "kbd_show"),
                              (UIResponder.keyboardWillHideNotification, "kbd_hide")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                MainActor.assumeIsolated { InputLatencyTrace.shared?.openWindow(label, duration: duration) }
            })
        }
    }

    private func openWindow(_ name: String, duration: Double) {
        let now = CACurrentMediaTime()
        // The iteration that posted the notification counts: it is open now.
        let start = watch.currentStart ?? now
        windows.append(KeyboardWindow(name: name, notified: now, start: start, end: now + max(duration, 0.05) + Self.windowTail))
        Self.signposter.emitEvent("keyboard", "\(name, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0.05) + Self.windowTail + 0.05) { [weak self] in
            self?.closeWindows()
        }
    }

    private func closeWindows() {
        let now = CACurrentMediaTime()
        while let first = windows.first, first.end < now {
            windows.removeFirst()
            sample("\(first.name)_free", ms: first.freeMs)
            sample("\(first.name)_max_iteration", ms: first.maxMs)
            sample("\(first.name)_iterations_over_4ms", ms: Double(first.count))
            write(#"{"type":"window","name":"\#(first.name)","free_ms":\#(Self.f(first.freeMs)),"max_ms":\#(Self.f(first.maxMs)),"over4":\#(first.count),"busy_ms":\#(Self.f(first.busyMs))}"#)
        }
    }

    // MARK: Board and file

    /// The counts and per-kind p50/p95/max so far, as one JSON object.
    public var summary: String {
        var parts = [#""hitches_8ms":\#(hitches8)"#, #""iterations_4ms":\#(iterations4)"#, #""max_iteration_ms":\#(Self.f(maxIterationMs))"#,
                     #""typing_keys":\#(typingKeys)"#, #""typing_hitches_8ms":\#(typingHitches8)"#,
                     #""typing_iterations_4ms":\#(typingIterations4)"#, #""typing_max_iteration_ms":\#(Self.f(typingMaxMs))"#]
        for (kind, count) in typingNotes.sorted(by: { $0.key < $1.key }) {
            parts.append(#""typing_\#(kind)":\#(count)"#)
        }
        for (kind, values) in samples.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count)).rounded(.up)) - 1))] }
            parts.append(#""\#(kind)":{"n":\#(sorted.count),"p50":\#(Self.f(p(0.5))),"p95":\#(Self.f(p(0.95))),"p99":\#(Self.f(p(0.99))),"max":\#(Self.f(sorted.last ?? 0))}"#)
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func write(_ line: String) {
        writer.async { [weak self] in self?.writeNow(line) }
    }

    nonisolated private func writeNow(_ line: String) {
        // Only the writer queue calls this; the handle is set once in init.
        handle?.write(Data((line + "\n").utf8))
    }

    nonisolated static func f(_ value: Double) -> String { String(format: "%.1f", value) }

    nonisolated static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `image symbol+offset` for a return address (dladdr; Swift names stay mangled,
    /// `xcrun swift-demangle` reads them).
    nonisolated static func symbol(for address: UInt) -> String {
        var info = Dl_info()
        guard address != 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let name = info.dli_sname, let base = info.dli_saddr else {
            return String(format: "%@ 0x%lx", image, address)
        }
        let offset = address &- UInt(bitPattern: base)
        return "\(image) \(String(cString: name))+\(offset)"
    }
}

/// One keyboard notification's window on the main thread.
struct KeyboardWindow {
    let name: String
    let notified: CFTimeInterval
    let start: CFTimeInterval
    let end: CFTimeInterval
    private(set) var count = 0
    private(set) var maxMs = 0.0
    private(set) var busyMs = 0.0
    /// From the notification to the end of the last iteration of 4 ms and more in the window.
    private(set) var freeMs = 0.0

    init(name: String, notified: CFTimeInterval, start: CFTimeInterval, end: CFTimeInterval) {
        self.name = name
        self.notified = notified
        self.start = start
        self.end = end
    }

    func contains(_ time: CFTimeInterval) -> Bool { time >= start && time <= end }

    mutating func add(_ iteration: MainThreadWatch.Iteration) {
        let ms = (iteration.end - iteration.start) * 1000
        count += 1
        busyMs += ms
        maxMs = max(maxMs, ms)
        freeMs = max(freeMs, (iteration.end - notified) * 1000)
    }
}

/// The main run loop's current iteration, shared with a watchdog thread that
/// samples the main thread's stack while an iteration runs long.
final class MainThreadWatch: @unchecked Sendable {
    struct Iteration: Sendable {
        var start: CFTimeInterval
        var end: CFTimeInterval
        var stacks: [[UInt]]
    }

    /// Sample every this long while an iteration runs (s).
    static let interval = 0.004
    /// `CMUX_MOBILE_INPUT_LATENCY_MAX_STACKS` / `_MAX_FRAMES` raise these for a
    /// bench that needs a long iteration sampled to its end and whole stacks.
    static let maxStacks = ProcessInfo.processInfo.environment["CMUX_MOBILE_INPUT_LATENCY_MAX_STACKS"].flatMap(Int.init) ?? 16
    static let maxFrames = ProcessInfo.processInfo.environment["CMUX_MOBILE_INPUT_LATENCY_MAX_FRAMES"].flatMap(Int.init) ?? 64

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Written only while main is suspended: no allocation may happen then
    /// (main may hold the allocator's lock).
    private let buffer: UnsafeMutablePointer<UInt>
    private let mainThread: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt

    // Guarded by `lock`.
    private var iterationStart: CFTimeInterval?
    private var lastSample: CFTimeInterval = 0
    private var stacks: [[UInt]] = []

    /// Created on the main thread.
    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        buffer = .allocate(capacity: Self.maxFrames)
        mainThread = mach_thread_self()
        let pthread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread))
        stackHigh = top
        stackLow = top &- UInt(pthread_get_stacksize_np(pthread))
    }

    var currentStart: CFTimeInterval? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return iterationStart
    }

    func begin(at time: CFTimeInterval) {
        os_unfair_lock_lock(lock)
        iterationStart = time
        lastSample = time
        stacks.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(lock)
    }

    /// The iteration that ends now (nil when none was open).
    func end(at time: CFTimeInterval) -> Iteration? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let start = iterationStart else { return nil }
        iterationStart = nil
        let iteration = Iteration(start: start, end: time, stacks: stacks)
        stacks.removeAll(keepingCapacity: true)
        return iteration
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "dev.cmux.mobile.main-watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        while true {
            usleep(1000)
            let now = CACurrentMediaTime()
            os_unfair_lock_lock(lock)
            let due = iterationStart != nil && now - lastSample >= Self.interval && stacks.count < Self.maxStacks
            os_unfair_lock_unlock(lock)
            guard due else { continue }
            let stack = sample()
            os_unfair_lock_lock(lock)
            // Only while the same iteration still runs: a sample after it ended is another iteration's.
            if iterationStart != nil {
                stacks.append(stack)
                lastSample = now
            }
            os_unfair_lock_unlock(lock)
        }
    }

    /// The main thread's return addresses, innermost first.
    fileprivate func sample() -> [UInt] {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        var count = 0
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        if result == KERN_SUCCESS {
            buffer[0] = UInt(state.__pc)
            buffer[1] = UInt(state.__lr)
            count = 2
            var frame = UInt(state.__fp)
            while count < Self.maxFrames, frame >= stackLow, frame &+ 16 <= stackHigh, frame % 8 == 0 {
                let words = UnsafePointer<UInt>(bitPattern: frame)!
                let next = words[0]
                let returnAddress = words[1]
                if returnAddress == 0 { break }
                buffer[count] = returnAddress
                count += 1
                if next <= frame { break }
                frame = next
            }
        }
        thread_resume(mainThread)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
        #else
        return []
        #endif
    }
}

/// A display link that fires once, at the next frame, then stops.
@MainActor
private final class NextFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?
    private static var live: Set<NextFrame> = []

    static func after(_ action: @escaping @MainActor () -> Void) {
        let frame = NextFrame()
        frame.action = action
        let link = CADisplayLink(target: frame, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        frame.link = link
        live.insert(frame)
    }

    @objc private func step() {
        link?.invalidate()
        link = nil
        Self.live.remove(self)
        let action = action
        self.action = nil
        action?()
    }
}

/// The trace's counts for a UI test to read.
@MainActor
@Observable
public final class InputLatencyBoard {
    public static let shared: InputLatencyBoard? = InputLatencyTrace.isEnabled ? InputLatencyBoard() : nil

    public private(set) var text = "{}"

    func update(_ summary: String) { text = summary }
}

/// The board as a nearly transparent label (`debug.input-latency`), over the app's root.
public struct InputLatencyProbe: View {
    public init() {}

    public var body: some View {
        if let board = InputLatencyBoard.shared {
            Text(board.text)
                .lineLimit(1)
                .frame(width: 4, height: 4)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.input-latency")
                .accessibilityLabel(board.text)
        }
    }
}
#endif
