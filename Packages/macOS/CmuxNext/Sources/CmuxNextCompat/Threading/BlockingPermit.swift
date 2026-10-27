/// Proof for the compiler that the code holding it runs where it may block: a `BackgroundWork` lane body
/// (`work.run(priority, mayBlock: .files) { permit in ... }`, a `WorkSequence`, `runHandle` or `resolveHost` body),
/// a ``MayBlockRunner`` or ``ChildProcessLauncher`` body, or the body of a reviewed ``allowBlocking(_:_:)`` scope.
/// Chrome's `ScopedAllowBlocking` friend list (base/threading/thread_restrictions.h) as a type.
///
/// Every blocking seam of this directory (file, socket, process, sync-wait, SQLite, Security, system-query and
/// system-call seams, ``CheckedFileManager``, ``CheckedImageSource/init(blockingContentsOf:_:options:fileID:line:)``)
/// has an overload that takes the permit and is `noasync`; the permit-less form is deprecated, so `swift build`
/// lists every seam call that has no lane (the MQ-23 queue of plans/cmux-next/chrome-parity/p02-threads.md:
/// `swift build 2>&1 | rg 'is deprecated: Pass the BlockingPermit|unavailable from asynchronous'`). The
/// ``BlockingKind/cpuIntensive`` seams take no permit: long CPU work is the job of a lane and of the pool alike,
/// and only the main thread disallows it.
///
/// It is `~Copyable` and not `Sendable`: a body gets it `borrowing`, so it cannot be stored, captured by an
/// escaping closure or sent to another thread. Only Compat and CmuxNextWakeups make one.
///
/// It proves only that the code has a lane; the run-time detector (``blockingCall(_:fileID:line:_:)``) still
/// checks which one, so a seam in a `.cpu` job still records a ``BlockingKind/wrongLane`` site.
///
/// ```swift
/// let bytes = try await work.run(.userVisible, mayBlock: .files) { permit in
///     try Data(blockingContentsOf: url, permit)
/// }
/// ```
public struct BlockingPermit: ~Copyable {
    /// What gave a permit.
    public enum Issuer: Sendable, Equatable {
        /// A `BackgroundWork` lane item or a ``MayBlockRunner`` body.
        case lane
        /// A dedicated queue that owns its work: a ``ChildProcessLauncher`` item.
        case dedicated
        /// A reviewed ``allowBlocking(_:_:)`` scope (a ``BlockingAllowance``).
        case allowance
    }

    /// What gave this permit.
    public let issuer: Issuer

    /// A permit for one lane item, launcher item or allowance body. Package-internal: CmuxNextWakeups' lanes and
    /// this module's runners, launchers and allowances are the only issuers.
    package init(issuer: Issuer) {
        self.issuer = issuer
    }
}

@available(*, unavailable, message: "A BlockingPermit stays in the body that got it")
extension BlockingPermit: Sendable {}

/// ``blockingCall(_:fileID:line:_:)`` for a seam overload that takes a ``BlockingPermit``: the same check and
/// timing, unavailable from async code.
///
/// - Parameters:
///   - kind: What the call waits on.
///   - permit: The permit of the lane or allowance body the call runs in.
///   - fileID: The calling code's `#fileID` (a seam passes its own caller's).
///   - line: The calling code's `#line`.
///   - body: The blocking work.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable @inline(__always)
public func blockingCall<Result, Failure: Error>(
    _ kind: BlockingKind, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line,
    _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    try blockingCall(kind, fileID: fileID, line: line, body)
}

/// ``allowBlocking(_:_:)`` whose body gets a ``BlockingPermit`` (issuer ``BlockingPermit/Issuer/allowance``) for
/// the seams it calls: the reviewed friend list gives the permit, as Chrome's `ScopedAllowBlocking` does. A
/// registered dedicated thread gets its permit this way.
///
/// - Parameters:
///   - reason: The reviewed allowance.
///   - body: The work that blocks.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
@available(*, noasync, message: "An allowance covers synchronous work on the calling thread only")
public func allowBlocking<Result, Failure: Error>(
    _ reason: BlockingAllowance, _ body: (borrowing BlockingPermit) throws(Failure) -> Result
) throws(Failure) -> Result {
    try blockingAllowanceScope(reason) { () throws(Failure) -> Result in
        try body(BlockingPermit(issuer: .allowance))
    }
}
