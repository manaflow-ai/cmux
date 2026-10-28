public import ApplicationServices

/// ``blockingAXCopyAttributeValue(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingAXCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>,
                                         _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    // SAFETY: forwards the caller's pointers to AXUIElementCopyAttributeValue unchanged, only for the call; the
    // caller's own `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { unsafe AXUIElementCopyAttributeValue(element, attribute, value) }
}

/// ``blockingAXSetAttributeValue(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingAXSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef,
                                        _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { AXUIElementSetAttributeValue(element, attribute, value) }
}

/// ``blockingAXPerformAction(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingAXPerformAction(_ element: AXUIElement, _ action: CFString,
                                    _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { AXUIElementPerformAction(element, action) }
}
