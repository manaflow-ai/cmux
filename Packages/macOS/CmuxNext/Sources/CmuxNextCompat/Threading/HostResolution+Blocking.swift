public import Darwin

/// Resolves a host name, like `getaddrinfo`, as a checked blocking call
/// (``assertBlockingAllowed(_:fileID:line:)``): it waits for mDNSResponder and the network. Chrome calls
/// it only from may-block workers (net/dns/host_resolver_system_task.cc); resolve off the main thread.
/// `fileID` and `line` name the caller.
///
/// - Returns: What `getaddrinfo` returns (0, or an `EAI_` error).
@inlinable
public func blockingGetaddrinfo(_ host: UnsafePointer<CChar>?, _ service: UnsafePointer<CChar>?, _ hints: UnsafePointer<addrinfo>?,
                                _ result: UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>?>,
                                fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return getaddrinfo(host, service, hints, result)
}
