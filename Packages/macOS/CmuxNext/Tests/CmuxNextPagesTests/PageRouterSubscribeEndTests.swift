import CmuxNextCompat
import CmuxNextSettings
@testable import CmuxNextPages
import Darwin
import Testing

/// A provider's `subscribe` that fails (it throws, or the page closed while it ran) ends the stream: an
/// event that provider still sends later, through the `onEvent` it kept, is dropped at once. The router
/// keeps nothing for it, so a provider that never lets go of `onEvent` cannot grow the router's memory
/// for the rest of a long session.
@MainActor @Suite(.serialized)
struct PageRouterSubscribeEndTests {
    static let descriptor = PageDescriptor(id: "cmux.end-test", resource: "end-test", namespaces: ["cmux.end."])

    struct Refused: Error {}

    /// Keeps `onEvent` whatever happens, as a provider that misses its cancel would; then fails as told.
    final class KeepingProvider: PageProvider {
        enum Ending { case throwing, closingThePage }
        let ending: Ending
        var onEvent: (@MainActor (JSONValue) -> Void)?
        weak var router: PageRouter?

        init(_ ending: Ending) { self.ending = ending }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            self.onEvent = onEvent
            switch ending {
            case .throwing: throw Refused()
            case .closingThePage:
                router?.close()
                return PageSubscription {}
            }
        }
    }

    @Test(arguments: [KeepingProvider.Ending.throwing, .closingThePage])
    func aFailedSubscribeKeepsNothingForEventsSentAfterIt(_ ending: KeepingProvider.Ending) async throws {
        let provider = KeepingProvider(ending)
        let router = PageRouter(descriptor: Self.descriptor, routes: [PageRoute(prefix: "cmux.end.", provider: provider)])
        provider.router = router
        var sent = 0
        router.send = { _ in sent += 1 }
        let reply = await router.handle(["t": "sub", "id": 1, "stream": "cmux.end.feed"])
        #expect(reply["t"]?.stringValue == "err", "the subscribe did not fail: \(reply)")
        let onEvent = try #require(provider.onEvent)
        let event: JSONValue = ["n": 1]
        onEvent(event) // warm-up outside the count: a first call may resolve metadata
        let control = mainThreadAllocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        // A list that kept each event would grow (and reallocate) as these arrive. The same loop with nothing in
        // it is the baseline: a Debug build's for-in over a range allocates once per iteration on the fleet
        // (10 000 for 10 000, probe 5529e509), so only what the events add counts.
        let loop = try #require(mainThreadAllocations { for _ in 0..<10_000 {} })
        let measured = try #require(mainThreadAllocations { for _ in 0..<10_000 { onEvent(event) } })
        let kept = measured - loop
        #expect(kept == 0, "the router kept \(kept) allocations' worth of events for a stream that ended (loop alone: \(loop))")
        #expect(sent == 0, "an event of a failed subscribe reached the page")
        withExtendedLifetime(router) {}
    }
}

// MARK: Counting the main thread's allocations

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private enum PageEndMallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
}

/// Counts the counted thread's allocations (and reallocations); allocates nothing itself.
nonisolated private func tallyPageEndMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == PageEndMallocTally.thread.load(ordering: .relaxed) else { return }
    _ = PageEndMallocTally.allocations.add(1, ordering: .relaxed)
}

/// How many heap allocations the calling thread makes in `body` (other threads left out), through libmalloc's
/// `malloc_logger` hook (as CrashKeySlotsTests counts); nil when libmalloc exports no hook.
private func mainThreadAllocations(_ body: () -> Void) -> Int? {
    // RTLD_DEFAULT, a C macro Swift does not import.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let hook = symbol.assumingMemoryBound(to: MallocLogger?.self)
    PageEndMallocTally.allocations.store(0, ordering: .relaxed)
    PageEndMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
    let previous = hook.pointee
    hook.pointee = tallyPageEndMalloc
    body()
    hook.pointee = previous
    PageEndMallocTally.thread.store(0, ordering: .relaxed)
    return PageEndMallocTally.allocations.load(ordering: .relaxed)
}
