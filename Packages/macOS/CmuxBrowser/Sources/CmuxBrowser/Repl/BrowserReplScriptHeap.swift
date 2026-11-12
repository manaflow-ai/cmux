import Darwin
import Foundation
import JavaScriptCore

/// The size of a REPL session's JavaScript heap, as JavaScriptCore measures
/// it, so the session can hold it in its resource ledger
/// (``BrowserReplResource/scriptHeapBytes``).
///
/// JavaScriptCore has no heap limit a context can set: neither its public
/// API nor its exported SPI can refuse an allocation past a size. What it
/// exports is a measure, `JSGetMemoryUsageStatistics` (`heapSize`: the
/// heap's objects plus the extra memory they report, such as string and
/// `ArrayBuffer` contents), and a synchronous full collection,
/// `JSSynchronousGarbageCollectForDebugging`. Both are declared in
/// non-public headers, so they are resolved with `dlsym`, as
/// ``BrowserReplWatchdog`` resolves the execution time limit. The measure
/// walks the heap's objects, so it costs time in proportion to them; the
/// session measures after each cell and otherwise at most a share of the
/// thread's time. A context's `JSContext()` has its own virtual machine,
/// so the measure is the session's alone.
///
/// Call only on the context's thread.
struct BrowserReplScriptHeap {
    private typealias StatisticsFunction = @convention(c) (JSContextRef?) -> JSObjectRef?
    private typealias CollectFunction = @convention(c) (JSContextRef?) -> Void

    private static let statistics: StatisticsFunction? = dlsym(dlopen(nil, RTLD_LAZY), "JSGetMemoryUsageStatistics")
        .map { unsafeBitCast($0, to: StatisticsFunction.self) }
    private static let collectNow: CollectFunction? = dlsym(dlopen(nil, RTLD_LAZY), "JSSynchronousGarbageCollectForDebugging")
        .map { unsafeBitCast($0, to: CollectFunction.self) }

    let context: JSContext

    /// The heap's size in bytes, garbage not yet collected included, or
    /// nil when this JavaScriptCore does not export the measure: the
    /// larger of `heapCapacity` (the blocks the heap holds, their free
    /// space included) and `heapSize`.
    func size() -> Int? {
        guard let statistics = Self.statistics, let ref = context.jsGlobalContextRef,
              let object = statistics(ref),
              let report = JSValue(jsValueRef: object, in: context) else { return nil }
        let bytes = ["heapCapacity", "heapSize"].compactMap { key -> Double? in
            guard let value = report.objectForKeyedSubscript(key), value.isNumber else { return nil }
            let number = value.toDouble()
            return number.isFinite && number >= 0 ? number : nil
        }.max()
        return bytes.map { Int(min($0, Double(Int.max / 2))) }
    }

    /// Collects the heap's garbage now, so ``size()`` then counts what
    /// the session's JavaScript can still reach. Without the export it
    /// asks for a collection, which JavaScriptCore may run later.
    func collect() {
        guard let ref = context.jsGlobalContextRef else { return }
        if let collectNow = Self.collectNow {
            collectNow(ref)
        } else {
            JSGarbageCollect(ref)
        }
    }
}
