public import Darwin

/// ``blockingGetaddrinfo(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingGetaddrinfo(_ host: UnsafePointer<CChar>?, _ service: UnsafePointer<CChar>?, _ hints: UnsafePointer<addrinfo>?,
                                _ result: UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>?>,
                                _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    // SAFETY: forwards the caller's pointers to getaddrinfo unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { unsafe getaddrinfo(host, service, hints, result) }
}
