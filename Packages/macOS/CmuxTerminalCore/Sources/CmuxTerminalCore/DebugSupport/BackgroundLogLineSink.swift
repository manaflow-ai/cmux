/// The destination for fully-formatted background-log lines.
///
/// Injecting this seam keeps ``BackgroundLogWriter`` free of any hard-coded
/// filesystem dependency: production uses ``FileBackgroundLogLineSink`` (appends
/// to a file through one long-lived handle), while tests substitute an in-memory
/// sink and assert on the lines deterministically — no temp files, no polling.
///
/// `write(_:)` is called by the writer's single consumer task, once per delivered
/// line, in FIFO order. The `async` requirement lets a conforming `actor` provide
/// isolation without an `@unchecked Sendable` escape hatch.
public protocol BackgroundLogLineSink: Sendable {
    func write(_ line: String) async
}
