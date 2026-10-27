/// Runs `body`, a synchronous call into a C library that reads files or waits inside it, as a checked blocking call
/// of kind ``BlockingKind/ffi`` (``blockingCall(_:fileID:line:_:)``, Chrome's `base::ScopedBlockingCall` around a
/// third-party call, base/threading/scoped_blocking_call.h).
///
/// One scope covers the whole C sequence: libghostty's config build (`ghostty_config_new`, the
/// `ghostty_config_load_*` calls and `ghostty_config_finalize`) is one call site, built on a lane that may block,
/// never on the main thread.
///
/// ```swift
/// let built = blockingFFI { makeConfig(inputs) }
/// ```
///
/// - Parameters:
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
///   - body: The C calls.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
@inlinable @inline(__always)
public func blockingFFI<Result, Failure: Error>(
    fileID: StaticString = #fileID, line: UInt = #line, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    try blockingCall(.ffi, fileID: fileID, line: line, body)
}
