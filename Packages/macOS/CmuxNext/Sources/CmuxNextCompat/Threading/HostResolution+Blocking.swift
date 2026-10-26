public import Darwin

/// Resolves a host name, like `getaddrinfo`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): it waits for mDNSResponder and the network. Chrome calls
/// it only from may-block workers (net/dns/host_resolver_system_task.cc); resolve off the main thread.
///
/// - Parameters:
///   - host: The host name or numeric address, or nil.
///   - service: The service name or port number, or nil.
///   - hints: The address family, socket type and flags wanted, or nil.
///   - result: Receives the address list; free it with `freeaddrinfo`.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `getaddrinfo` returns (0, or an `EAI_` error).
@inlinable
public func blockingGetaddrinfo(_ host: UnsafePointer<CChar>?, _ service: UnsafePointer<CChar>?, _ hints: UnsafePointer<addrinfo>?,
                                _ result: UnsafeMutablePointer<UnsafeMutablePointer<addrinfo>?>,
                                fileID: StaticString = #fileID, line: UInt = #line) -> Int32 {
    return blockingCall(.systemCall, fileID: fileID, line: line) { getaddrinfo(host, service, hints, result) }
}
