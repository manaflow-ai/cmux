#if canImport(ApplicationServices)
public import ApplicationServices

/// Reads an attribute, like `AXUIElementCopyAttributeValue`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``): it sends a Mach message to the element's app and waits
/// for the answer, up to the messaging timeout (6 s by default).
///
/// - Parameters:
///   - element: The element.
///   - attribute: The attribute's name.
///   - value: Receives the attribute's value.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `AXUIElementCopyAttributeValue` returns.
@inlinable
public func blockingAXCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>,
                                         fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    // SAFETY: forwards the caller's pointers to AXUIElementCopyAttributeValue unchanged, only for the call; the
    // caller's own `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe AXUIElementCopyAttributeValue(element, attribute, value) }
}

/// Sets an attribute, like `AXUIElementSetAttributeValue`, as a checked blocking call: it waits for the
/// element's app, up to the messaging timeout.
///
/// - Parameters:
///   - element: The element.
///   - attribute: The attribute's name.
///   - value: The new value.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `AXUIElementSetAttributeValue` returns.
@inlinable
public func blockingAXSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef,
                                        fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    return blockingCall(.systemCall, fileID: fileID, line: line) { AXUIElementSetAttributeValue(element, attribute, value) }
}

/// Performs an action, like `AXUIElementPerformAction`, as a checked blocking call: it waits for the
/// element's app, up to the messaging timeout.
///
/// - Parameters:
///   - element: The element.
///   - action: The action's name.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `AXUIElementPerformAction` returns.
@inlinable
public func blockingAXPerformAction(_ element: AXUIElement, _ action: CFString,
                                    fileID: StaticString = #fileID, line: UInt = #line) -> AXError {
    return blockingCall(.systemCall, fileID: fileID, line: line) { AXUIElementPerformAction(element, action) }
}
#endif
