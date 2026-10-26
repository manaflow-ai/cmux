public import Darwin

/// ``blockingRead(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.socketRead, permit, fileID: fileID, line: line) { Darwin.read(descriptor, buffer, count) }
}

/// ``blockingRecv(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingRecv(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: Int32, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.socketRead, permit, fileID: fileID, line: line) { Darwin.recv(descriptor, buffer, count, flags) }
}

/// ``blockingWrite(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int,
                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.socketWrite, permit, fileID: fileID, line: line) { Darwin.write(descriptor, buffer, count) }
}

/// ``blockingSend(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32,
                         _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Int {
    return blockingCall(.socketWrite, permit, fileID: fileID, line: line) { Darwin.send(descriptor, buffer, count, flags) }
}
