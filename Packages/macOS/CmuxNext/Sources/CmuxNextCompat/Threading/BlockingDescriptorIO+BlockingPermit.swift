public import Darwin

/// ``blockingRead(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to read unchanged, only for the call; the caller's own `unsafe` states why
    // they are valid for it.
    return blockingCall(.socketRead, permit, fileID: fileID, line: line) { unsafe Darwin.read(descriptor, buffer, count) }
}

/// ``blockingRecv(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRecv(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: Int32, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to recv unchanged, only for the call; the caller's own `unsafe` states why
    // they are valid for it.
    return blockingCall(.socketRead, permit, fileID: fileID, line: line) { unsafe Darwin.recv(descriptor, buffer, count, flags) }
}

/// ``blockingWrite(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int,
                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to write unchanged, only for the call; the caller's own `unsafe` states
    // why they are valid for it.
    return blockingCall(.socketWrite, permit, fileID: fileID, line: line) { unsafe Darwin.write(descriptor, buffer, count) }
}

/// ``blockingSend(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32,
                         _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    // SAFETY: forwards the caller's pointers to send unchanged, only for the call; the caller's own `unsafe` states why
    // they are valid for it.
    return blockingCall(.socketWrite, permit, fileID: fileID, line: line) { unsafe Darwin.send(descriptor, buffer, count, flags) }
}
