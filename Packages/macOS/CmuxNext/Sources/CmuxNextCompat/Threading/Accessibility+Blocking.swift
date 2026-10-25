public import ApplicationServices

// Checked seams over Accessibility calls: each one is a Mach message to the element's app that waits
// for its answer, up to the messaging timeout (6 s by default)
// (``assertBlockingAllowed(_:fileID:line:)``). Each forwards its caller's `fileID` and `line`.

/// Reads an attribute, like `AXUIElementCopyAttributeValue`, as a checked blocking call.
///
/// - Returns: What `AXUIElementCopyAttributeValue` returns.
@inlinable
public func blockingAXCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>,
                                         fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return AXUIElementCopyAttributeValue(element, attribute, value)
}

/// Sets an attribute, like `AXUIElementSetAttributeValue`, as a checked blocking call.
///
/// - Returns: What `AXUIElementSetAttributeValue` returns.
@inlinable
public func blockingAXSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef,
                                        fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return AXUIElementSetAttributeValue(element, attribute, value)
}

/// Performs an action, like `AXUIElementPerformAction`, as a checked blocking call.
///
/// - Returns: What `AXUIElementPerformAction` returns.
@inlinable
public func blockingAXPerformAction(_ element: AXUIElement, _ action: CFString,
                                    fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return AXUIElementPerformAction(element, action)
}
