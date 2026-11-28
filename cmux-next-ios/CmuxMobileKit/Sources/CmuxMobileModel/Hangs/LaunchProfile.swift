#if os(iOS) && DEBUG
import Darwin
import Foundation
import QuartzCore

/// Where the main thread's time goes at launch (DEBUG, `CMUX_MOBILE_LAUNCH_PROFILE=1`; `LaunchTTIUITests`
/// passes it on from `TEST_RUNNER_CMUX_MOBILE_LAUNCH_PROFILE`). From `App.init`, a thread samples the
/// main thread's stack every 2 ms with ``ThreadStackSampler`` (the walk that is safe at launch), for 12 s
/// at most. ``finish(nowMs:windows:done:)`` stops it and, off the main thread, counts each function's
/// samples in each window of the launch marks: inclusive (on the stack), self (the innermost frame), and
/// this app's own functions, who calls `os_log`, who waits on a lock, and who looks up a protocol conformance. The report is one JSON line.
///
/// Off, nothing runs. On, one thread and one stack (128 frames) per 2 ms, for 12 s at most.
public final class LaunchProfile: @unchecked Sendable { // crash-allow: `samples` and `stopped` are guarded by `lock`
    public static let shared: LaunchProfile? =
        ProcessInfo.processInfo.environment["CMUX_MOBILE_LAUNCH_PROFILE"] == "1" ? LaunchProfile() : nil

    /// Between samples (µs).
    static let interval: useconds_t = 2000
    /// The longest it samples (s).
    static let bound: CFTimeInterval = 12

    private let sampler: ThreadStackSampler
    private let lock = NSLock()
    private var samples: [(time: CFTimeInterval, stack: [UInt])] = []
    private var stopped = false

    /// Made on the main thread (the sampled one).
    private init() {
        sampler = ThreadStackSampler(thread: mach_thread_self(), maxFrames: 128)
        samples.reserveCapacity(Int(Self.bound * 1_000_000 / Double(Self.interval)))
    }

    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "dev.cmux.mobile.launch-profile"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        let begin = CACurrentMediaTime()
        while true {
            usleep(Self.interval)
            let now = CACurrentMediaTime()
            lock.lock()
            let done = stopped
            lock.unlock()
            if done || now - begin > Self.bound { return }
            let stack = sampler.sample()
            guard !stack.isEmpty else { continue }
            lock.lock()
            samples.append((now, stack))
            lock.unlock()
        }
    }

    /// Stops sampling and reports each window (`name`, from, to: ms since the process started, as
    /// `nowMs`, the same clock read now) to `done`, off the main thread.
    public func finish(nowMs: Double, windows: [(name: String, from: Double, to: Double)], done: @escaping @Sendable (String) -> Void) {
        let offset = nowMs - CACurrentMediaTime() * 1000
        lock.lock()
        stopped = true
        let all = samples
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            done(Self.report(all, offset: offset, windows: windows))
        }
    }

    static func report(_ samples: [(time: CFTimeInterval, stack: [UInt])], offset: Double,
                       windows: [(name: String, from: Double, to: Double)]) -> String {
        var names: [UInt: (name: String, own: Bool)] = [:]
        let appImage = Bundle.main.executableURL?.lastPathComponent ?? ""
        func symbol(_ address: UInt) -> (name: String, own: Bool) {
            if let known = names[address] { return known }
            let found = Self.symbol(address, appImage: appImage)
            names[address] = found
            return found
        }
        var out: [[String: Any]] = []
        for window in windows {
            let inWindow = samples.filter { let ms = $0.time * 1000 + offset; return ms >= window.from && ms < window.to }
            var inclusive: [String: Int] = [:]
            var innermost: [String: Int] = [:]
            var own: [String: Int] = [:]
            var logCallers: [String: Int] = [:]
            var waitCallers: [String: Int] = [:]
            var conformsCallers: [String: Int] = [:]
            for sample in inWindow {
                let names = sample.stack.map { symbol($0).name }
                // Who logs, and who waits: the five frames out from the outermost os_log frame, and
                // from the innermost wait past the lock's own frames.
                if let log = names.lastIndex(where: { $0.hasPrefix("libsystem_trace.dylib ") }) {
                    logCallers[names[(log + 1)...].prefix(5).joined(separator: " < "), default: 0] += 1
                }
                if names.first?.contains("__ulock_wait") == true {
                    let past = names.firstIndex { !$0.hasPrefix("libsystem_kernel.dylib ") && !$0.hasPrefix("libsystem_platform.dylib ") } ?? names.count
                    waitCallers[names[past...].prefix(5).joined(separator: " < "), default: 0] += 1
                }
                // Who asks the runtime for a protocol conformance (a cold `as?` or generic lookup scans
                // every conformance record): the five frames out past the runtime's own frames.
                if let lookup = names.prefix(8).firstIndex(where: { $0.contains("swift_conformsToProtocol") }) {
                    let past = names[lookup...].firstIndex { !$0.hasPrefix("libswiftCore.dylib ") } ?? names.count
                    conformsCallers[names[past...].prefix(5).joined(separator: " < "), default: 0] += 1
                }
                var seen = Set<String>()
                var seenOwn = Set<String>()
                for (index, address) in sample.stack.enumerated() {
                    let found = symbol(address)
                    if index == 0 { innermost[found.name, default: 0] += 1 }
                    if seen.insert(found.name).inserted { inclusive[found.name, default: 0] += 1 }
                    if found.own, seenOwn.insert(found.name).inserted { own[found.name, default: 0] += 1 }
                }
            }
            func top(_ counts: [String: Int], _ n: Int) -> [[Any]] {
                counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map { [$0.key, $0.value] }
            }
            out.append(["name": window.name, "from": window.from.rounded(), "to": window.to.rounded(), "n": inWindow.count,
                        "self": top(innermost, 15), "app": top(own, 45), "incl": top(inclusive, 35),
                        "log": top(logCallers, 20), "wait": top(waitCallers, 20),
                        "conforms": top(conformsCallers, 25)])
        }
        let object: [String: Any] = ["interval_ms": Double(interval) / 1000, "samples": samples.count, "windows": out]
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// `image name` for a return address, demangled, at most 140 characters; `own`: in this app's binary
    /// or its debug dylib.
    static func symbol(_ address: UInt, appImage: String) -> (name: String, own: Bool) {
        var info = Dl_info()
        guard address != 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return ("?", false) }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let own = !appImage.isEmpty && (image == appImage || image == appImage + ".debug.dylib")
        guard let raw = info.dli_sname else { return (image + " ?", own) }
        let name = demangle(String(cString: raw))
        return (String((image + " " + name).prefix(140)), own)
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static let swiftDemangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    static func demangle(_ name: String) -> String {
        guard let swiftDemangle else { return name }
        return name.withCString { pointer in
            guard let result = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }
}
#endif
