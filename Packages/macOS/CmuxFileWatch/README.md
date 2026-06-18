# CmuxFileWatch

Generic recursive-path filesystem watching, as a Wave-2 infrastructure leaf of
the cmux modular refactor.

`RecursivePathWatcher` is an `actor` that wraps an `FSEventStream` (hidden behind
`FileSystemEventStream`) and reports coalesced changes as an `AsyncStream<Void>`.
The caller decides which paths matter for its domain, constructs a watcher, and
reacts to each yielded element. It has no knowledge of what it is watching.

A leading-edge throttle folds a burst of filesystem events into a single yield.
The throttle delay is driven through the `FileWatchClock` seam: production uses
`SystemFileWatchClock` (a real `Task.sleep`); tests inject a clock that suspends
until released, so coalescing is verified deterministically with no real
waiting.

```swift
guard let watcher = RecursivePathWatcher(paths: paths) else { return }
let task = Task { @MainActor in
    for await _ in watcher.events { reload() }
}
// teardown
task.cancel()
await watcher.stop()
```

`FSEventStream` is the only macOS primitive that watches a *set of paths
recursively* with one coalescing stream, so it is used here rather than a
per-descriptor `DispatchSource` file source. The first consumer is the workspace
git-metadata watcher in `TabManager` (the git path-resolution logic stays there,
bound for `CmuxSidebarGit`). `CmuxSettings`' `JSONConfigFileWatcher` is a
candidate to migrate onto this package as a second consumer.

## Testing

`RecursivePathWatcher` takes its throttle clock via `FileWatchClock`, so the
coalescing behavior is testable with no real waiting. Conform a test clock whose
`sleep(for:)` suspends until the test releases it, then drive synthetic events
through the throttle and assert the yielded `events`. The package ships such a
gate clock in `Tests/CmuxFileWatchTests`:

```swift
private actor GateClock: FileWatchClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { sleepers.append($0) }
    }
    func releaseOne() { if !sleepers.isEmpty { sleepers.removeFirst().resume() } }
}

@Test func burstCoalescesIntoOneYield() async {
    let clock = GateClock()
    // The test-only initializer drives the throttle directly, with no FSEventStream.
    let watcher = RecursivePathWatcher(testThrottleClock: clock)
    var events = watcher.events.makeAsyncIterator()

    for _ in 0..<5 { await watcher.simulateFileSystemEventForTesting() }  // one window
    await clock.releaseOne()                                             // flush
    #expect(await events.next() != nil)                                  // exactly one yield

    await watcher.stop()
    #expect(await events.next() == nil)                                  // stream finished
}
```

Production code constructs the watcher with the default `SystemFileWatchClock`
and a real path set; only tests use the `testThrottleClock` initializer.
