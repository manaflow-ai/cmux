public import Darwin

/// ``blockingGetaddrinfo(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingGetaddrinfo(_ host: UnsafePointer<CChar>?, _ service: UnsafePointer<CChar>?, _ hints: UnsafePointer<addrinfo>?,
                                _ result: UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>?>,
                                _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { getaddrinfo(host, service, hints, result) }
}
