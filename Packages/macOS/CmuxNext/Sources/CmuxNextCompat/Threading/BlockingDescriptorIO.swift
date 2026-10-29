public import Darwin

/// Reads from a file descriptor, like `Darwin.read`, as a checked blocking call
/// (``assertBlockingAllowed(_:fileID:line:)``): a socket or pipe read waits for the peer.
///
/// - Parameters:
///   - descriptor: The descriptor to read.
///   - buffer: Where the bytes go.
///   - count: The most bytes to read.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `read(2)` returns.
@inlinable
public func blockingRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    assertBlockingAllowed(.socketRead, fileID: fileID, line: line)
    return Darwin.read(descriptor, buffer, count)
}

/// Receives from a socket, like `Darwin.recv`, as a checked blocking call
/// (``assertBlockingAllowed(_:fileID:line:)``).
///
/// - Parameters:
///   - descriptor: The socket.
///   - buffer: Where the bytes go.
///   - count: The most bytes to receive.
///   - flags: `recv(2)` flags.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `recv(2)` returns.
@inlinable
public func blockingRecv(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: Int32, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    assertBlockingAllowed(.socketRead, fileID: fileID, line: line)
    return Darwin.recv(descriptor, buffer, count, flags)
}

/// Writes to a file descriptor, like `Darwin.write`, as a checked blocking call
/// (``assertBlockingAllowed(_:fileID:line:)``): a socket or pipe write waits while the peer's
/// buffer is full.
///
/// - Parameters:
///   - descriptor: The descriptor to write.
///   - buffer: The bytes.
///   - count: How many bytes to write.
///   - fileID: The calling code's `#fileID`.
///   - line: The calling code's `#line`.
/// - Returns: What `write(2)` returns.
@inlinable
public func blockingWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int,
                          fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    assertBlockingAllowed(.socketWrite, fileID: fileID, line: line)
    return Darwin.write(descriptor, buffer, count)
}

/// Sends on a socket, like `Darwin.send`, as a checked blocking call
/// (``assertBlockingAllowed(_:fileID:line:)``).
///
/// - Parameters:
///   - descriptor: The socket.
///   - buffer: The bytes.
///   - count: How many bytes to send.
///   - flags: `send(2)` flags.
///   - fileID: The calling code's `#fileID`.
///   - line: The calling code's `#line`.
/// - Returns: What `send(2)` returns.
@inlinable
public func blockingSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32,
                         fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    assertBlockingAllowed(.socketWrite, fileID: fileID, line: line)
    return Darwin.send(descriptor, buffer, count, flags)
}
