public import Security

// Checked seams over Security calls that wait for securityd, authd or a prompt
// (``assertBlockingAllowed(_:fileID:line:)``, Chrome's `base::ScopedBlockingCall` in
// base/threading/scoped_blocking_call.h). Each forwards its caller's `fileID` and `line`; call them off
// the main thread.

/// Finds keychain items, like `SecItemCopyMatching`, as a checked blocking call.
///
/// - Returns: What `SecItemCopyMatching` returns.
@inlinable
public func blockingSecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                                        fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return SecItemCopyMatching(query, result)
}

/// Adds a keychain item, like `SecItemAdd`, as a checked blocking call.
///
/// - Returns: What `SecItemAdd` returns.
@inlinable
public func blockingSecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                               fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return SecItemAdd(attributes, result)
}

/// Changes keychain items, like `SecItemUpdate`, as a checked blocking call.
///
/// - Returns: What `SecItemUpdate` returns.
@inlinable
public func blockingSecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary,
                                  fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return SecItemUpdate(query, attributesToUpdate)
}

/// Deletes keychain items, like `SecItemDelete`, as a checked blocking call.
///
/// - Returns: What `SecItemDelete` returns.
@inlinable
public func blockingSecItemDelete(_ query: CFDictionary, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return SecItemDelete(query)
}

/// Evaluates a trust, like `SecTrustEvaluateWithError`, as a checked blocking call (it can fetch
/// revocation data from the network).
///
/// - Returns: Whether the trust is valid.
@inlinable
public func blockingSecTrustEvaluate(_ trust: SecTrust, _ error: UnsafeMutablePointer<CFError?>?,
                                     fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return SecTrustEvaluateWithError(trust, error)
}

/// Checks a code signature on disk, like `SecStaticCodeCheckValidityWithErrors`, as a checked blocking
/// call (it reads and hashes the code).
///
/// - Returns: What `SecStaticCodeCheckValidityWithErrors` returns.
@inlinable
public func blockingSecStaticCodeCheckValidity(_ code: SecStaticCode, _ flags: SecCSFlags, _ requirement: SecRequirement?,
                                               errors: UnsafeMutablePointer<Unmanaged<CFError>?>? = nil,
                                               fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    assertBlockingAllowed(.systemCall, fileID: fileID, line: line)
    return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, errors)
}

/// Asks authd for rights, like `AuthorizationCopyRights`, as a checked blocking call (it can wait for
/// the person to type a password).
///
/// - Returns: What `AuthorizationCopyRights` returns.
@inlinable
public func blockingAuthorizationCopyRights(
    _ authorization: AuthorizationRef, _ rights: UnsafePointer<AuthorizationRights>,
    _ environment: UnsafePointer<AuthorizationEnvironment>?, _ flags: AuthorizationFlags,
    _ authorizedRights: UnsafeMutablePointer<UnsafeMutablePointer<AuthorizationRights>?>?,
    fileID: StaticString = #fileID, line: UInt = #line
) -> OSStatus {
    assertBlockingAllowed(.ipcReply, fileID: fileID, line: line)
    return AuthorizationCopyRights(authorization, rights, environment, flags, authorizedRights)
}
