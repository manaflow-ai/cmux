import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// HOT PATH AUDIT frames, measurement only: where a layout motion frame's main-thread allocations come from. The count
/// probe found 1,064-1,779 allocations per frame (Debug), the same on the landing frame where no host changes, so most
/// of them do not depend on what moved. This probe records the call stack of every main-thread allocation of
/// `LayoutRootView.advanceFrame` (libmalloc's `malloc_logger` hook, `backtrace` into a buffer made before the hook is
/// installed: the hook allocates nothing), then names, per allocation, the first frame of our own modules and the
/// first frame that is not an allocator, and prints the top call sites. Run it in Release
/// (CMUX_SWIFT_SUITE_CONFIGURATION=release) for the shipped numbers. Prints `HPA-ALLOC` lines.
@MainActor @Suite(.serialized, .closesItsWindows)
struct MotionFrameAllocationSitesTests {
    @Test func whereAMotionFramesAllocationsComeFrom() async throws {
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 3, width: 0.25) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        // 1. A frame at rest (nothing moves; the driver would not tick, but a client sharing the clock does).
        try record("rest", frames: 20) { _ = probe.root.advanceFrame(1.0 / 120) }
        // 2. The frames of a spring (a close in a row column: 2 panes grow).
        var next = columns
        next[1] = PaneMotionBench.column(1, rows: 2, width: 0.25)
        probe.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(next))])
        for _ in 0..<4 { await Task.yield() }
        var moving = true
        try record("spring", frames: 40) {
            guard moving else { return }
            moving = probe.root.advanceFrame(1.0 / 120)
            probe.root.layoutSubtreeIfNeeded()
        }
    }

    private func record(_ name: String, frames: Int, _ frame: () -> Void) throws {
        frame() // warm-up: first-use statics, caches
        try #require(AllocSites.start(), "malloc_logger is not exported: the probe cannot record here")
        for _ in 0..<frames { frame() }
        let samples = AllocSites.stop()
        print("HPA-ALLOC case=\(name) frames=\(frames) allocations=\(samples.count) per_frame=\(String(format: "%.1f", Double(samples.count) / Double(frames))) dropped=\(AllocSites.dropped)")
        var ours: [String: Int] = [:], callers: [String: Int] = [:], images: [String: Int] = [:]
        for stack in samples {
            var caller: String?, own: String?, image: String?
            for pc in stack {
                let (symbol, file) = AllocSites.name(pc)
                if AllocSites.isAllocator(symbol) { continue }
                if caller == nil { caller = symbol; image = file }
                if own == nil, AllocSites.isOurs(symbol) { own = symbol }
                if caller != nil, own != nil { break }
            }
            callers[caller ?? "?", default: 0] += 1
            ours[own ?? "(no frame of ours)", default: 0] += 1
            images[image ?? "?", default: 0] += 1
        }
        func top(_ table: [String: Int], _ kind: String, _ count: Int) {
            for (site, n) in table.sorted(by: { $0.value > $1.value }).prefix(count) {
                print("HPA-ALLOC \(name) \(kind) \(String(format: "%.1f", Double(n) / Double(frames)))/frame \(site.prefix(200))")
            }
        }
        top(images, "image", 8)
        top(ours, "our-frame", 15)
        top(callers, "caller", 15)
    }
}

/// Records the main thread's allocation stacks (test only).
@MainActor
enum AllocSites {
    nonisolated static let depth = 28
    nonisolated static let capacity = 120_000
    nonisolated(unsafe) static var buffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: capacity * depth)
    nonisolated(unsafe) static var lengths = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var dropped = 0
    nonisolated(unsafe) static var thread: UInt32 = 0
    nonisolated(unsafe) static var inHook = false
    private static var previous: AllocSiteLogger?
    private static var cache: [UInt: (String, String)] = [:]

    static func start() -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return false }
        let hook = symbol.assumingMemoryBound(to: AllocSiteLogger?.self)
        count = 0
        dropped = 0
        thread = pthread_mach_thread_np(pthread_self())
        previous = hook.pointee
        hook.pointee = recordAllocSite
        return true
    }

    static func stop() -> [[UInt]] {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") {
            symbol.assumingMemoryBound(to: AllocSiteLogger?.self).pointee = previous
        }
        thread = 0
        return (0..<count).map { index in
            (0..<Int(lengths[index])).compactMap { frame in buffer[index * depth + frame].map { UInt(bitPattern: $0) } }
        }
    }

    static func name(_ pc: UInt) -> (String, String) {
        if let known = cache[pc] { return known }
        var info = Dl_info()
        var result = ("?", "?")
        if dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0 {
            let raw = info.dli_sname.map { String(cString: $0) } ?? "?"
            let file = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            result = (demangle(raw), file)
        }
        cache[pc] = result
        return result
    }

    private static func demangle(_ name: String) -> String {
        typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return name }
        let function = unsafeBitCast(symbol, to: Demangle.self)
        return name.withCString { pointer in
            guard let out = function(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(out) }
            return String(cString: out)
        }
    }

    static func isAllocator(_ symbol: String) -> Bool {
        let names = ["recordAllocSite", "malloc", "calloc", "realloc", "_malloc_zone", "swift_slowAlloc", "swift_allocObject",
                     "swift_allocBox", "_swift_allocObject", "_objc_rootAlloc", "class_createInstance", "_os_object_alloc",
                     "objc_alloc", "_objc_rootAllocWithZone", "operator new", "__CFAllocator", "_CFRuntimeCreateInstance",
                     "swift_initStackObject", "_ContiguousArrayStorage", "_allocateUninitialized", "nanov2", "szone", "_malloc"]
        return names.contains { symbol.contains($0) }
    }

    static func isOurs(_ symbol: String) -> Bool { symbol.contains("CmuxNext") }
}

typealias AllocSiteLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook: on the recorded thread, one stack per allocation into the preallocated buffer. Allocates nothing.
nonisolated func recordAllocSite(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    guard type & 2 != 0, pthread_mach_thread_np(pthread_self()) == AllocSites.thread, !AllocSites.inHook else { return }
    AllocSites.inHook = true
    defer { AllocSites.inHook = false }
    guard AllocSites.count < AllocSites.capacity else {
        AllocSites.dropped += 1
        return
    }
    let index = AllocSites.count
    let length = backtrace(AllocSites.buffer.advanced(by: index * AllocSites.depth), Int32(AllocSites.depth))
    AllocSites.lengths[index] = length
    AllocSites.count = index + 1
}
