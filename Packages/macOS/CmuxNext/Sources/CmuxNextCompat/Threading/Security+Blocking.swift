public import Security

/// Finds keychain items, like `SecItemCopyMatching`, as a checked blocking call
/// (``blockingCall(_:fileID:line:_:)``, Chrome's `base::ScopedBlockingCall` in
/// base/threading/scoped_blocking_call.h): it waits for securityd and can wait for a keychain prompt.
///
/// - Parameters:
///   - query: The search query.
///   - result: Receives the items found, or nil to only test for a match.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecItemCopyMatching` returns.
@inlinable
public func blockingSecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                                        fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecItemCopyMatching unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecItemCopyMatching(query, result) }
}

/// Adds a keychain item, like `SecItemAdd`, as a checked blocking call: it waits for securityd.
///
/// - Parameters:
///   - attributes: The new item's class, attributes and data.
///   - result: Receives the added item, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecItemAdd` returns.
@inlinable
public func blockingSecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                               fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecItemAdd unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecItemAdd(attributes, result) }
}

/// Changes keychain items, like `SecItemUpdate`, as a checked blocking call: it waits for securityd.
///
/// - Parameters:
///   - query: The items to change.
///   - attributesToUpdate: The new attribute values.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecItemUpdate` returns.
@inlinable
public func blockingSecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary,
                                  fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, fileID: fileID, line: line) { SecItemUpdate(query, attributesToUpdate) }
}

/// Deletes keychain items, like `SecItemDelete`, as a checked blocking call: it waits for securityd.
///
/// - Parameters:
///   - query: The items to delete.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecItemDelete` returns.
@inlinable
public func blockingSecItemDelete(_ query: CFDictionary, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, fileID: fileID, line: line) { SecItemDelete(query) }
}

/// Evaluates a trust, like `SecTrustEvaluateWithError`, as a checked blocking call: it waits for
/// trustd, which can fetch revocation data from the network.
///
/// - Parameters:
///   - trust: The trust to evaluate.
///   - error: Receives the reason the trust is not valid, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: Whether the trust is valid.
@inlinable
public func blockingSecTrustEvaluate(_ trust: SecTrust, _ error: UnsafeMutablePointer<CFError?>?,
                                     fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
    // SAFETY: forwards the caller's pointers to SecTrustEvaluateWithError unchanged, only for the call; the caller's
    // own `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecTrustEvaluateWithError(trust, error) }
}

/// Checks a code signature on disk, like `SecStaticCodeCheckValidityWithErrors`, as a checked blocking
/// call: it reads and hashes the code.
///
/// - Parameters:
///   - code: The code on disk.
///   - flags: The checks to make.
///   - requirement: A requirement the code must also satisfy, or nil.
///   - errors: Receives the reason the check failed, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecStaticCodeCheckValidityWithErrors` returns.
@inlinable
public func blockingSecStaticCodeCheckValidity(_ code: SecStaticCode, _ flags: SecCSFlags, _ requirement: SecRequirement?,
                                               errors: UnsafeMutablePointer<Unmanaged<CFError>?>? = nil,
                                               fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecStaticCodeCheckValidityWithErrors unchanged, only for the call; the
    // caller's own `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecStaticCodeCheckValidityWithErrors(code, flags, requirement, errors) }
}

/// The running process's code, like `SecCodeCopySelf`, as a checked blocking call: it asks the kernel
/// and the code signing daemon for this process's signature state.
///
/// - Parameters:
///   - flags: The options.
///   - code: Receives this process's code.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecCodeCopySelf` returns.
@inlinable
public func blockingSecCodeCopySelf(_ flags: SecCSFlags, _ code: UnsafeMutablePointer<SecCode?>,
                                    fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecCodeCopySelf unchanged, only for the call; the caller's own `unsafe`
    // states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecCodeCopySelf(flags, code) }
}

/// The code on disk of running code, like `SecCodeCopyStaticCode`, as a checked blocking call: it finds
/// and opens the code's file.
///
/// - Parameters:
///   - code: The running code.
///   - flags: The options.
///   - staticCode: Receives the code on disk.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecCodeCopyStaticCode` returns.
@inlinable
public func blockingSecCodeCopyStaticCode(_ code: SecCode, _ flags: SecCSFlags, _ staticCode: UnsafeMutablePointer<SecStaticCode?>,
                                          fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecCodeCopyStaticCode unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecCodeCopyStaticCode(code, flags, staticCode) }
}

/// The signing information of code, like `SecCodeCopySigningInformation`, as a checked blocking call:
/// it reads, and for some flags hashes, the code on disk.
///
/// - Parameters:
///   - code: The code on disk.
///   - flags: The information to read (`kSecCSSigningInformation` and others).
///   - information: Receives the information dictionary.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecCodeCopySigningInformation` returns.
@inlinable
public func blockingSecCodeCopySigningInformation(_ code: SecStaticCode, _ flags: SecCSFlags,
                                                  _ information: UnsafeMutablePointer<CFDictionary?>,
                                                  fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecCodeCopySigningInformation unchanged, only for the call; the
    // caller's own `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecCodeCopySigningInformation(code, flags, information) }
}

/// The designated requirement of code, like `SecCodeCopyDesignatedRequirement`, as a checked blocking call: it
/// reads the code's signature on disk.
///
/// - Parameters:
///   - code: The code on disk (or running code).
///   - flags: The options.
///   - requirement: Receives the requirement.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecCodeCopyDesignatedRequirement` returns.
@inlinable
public func blockingSecCodeCopyDesignatedRequirement(_ code: SecStaticCode, _ flags: SecCSFlags,
                                                     _ requirement: UnsafeMutablePointer<SecRequirement?>,
                                                     fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecCodeCopyDesignatedRequirement unchanged, only for the call; the
    // caller's own `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecCodeCopyDesignatedRequirement(code, flags, requirement) }
}

/// The guest code a host names by attributes (an audit token or a pid), like
/// `SecCodeCopyGuestWithAttributes`, as a checked blocking call: it asks the kernel and the code signing
/// daemon about the other process.
///
/// - Parameters:
///   - host: The host code, or nil for the kernel.
///   - attributes: The guest's attributes (`kSecGuestAttributeAudit`, `kSecGuestAttributePid`).
///   - flags: The options.
///   - guest: Receives the guest's code.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `SecCodeCopyGuestWithAttributes` returns.
@inlinable
public func blockingSecCodeCopyGuestWithAttributes(_ host: SecCode?, _ attributes: CFDictionary?, _ flags: SecCSFlags,
                                                   _ guest: UnsafeMutablePointer<SecCode?>,
                                                   fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    // SAFETY: forwards the caller's pointers to SecCodeCopyGuestWithAttributes unchanged, only for the call; the
    // caller's own `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe SecCodeCopyGuestWithAttributes(host, attributes, flags, guest) }
}

/// Asks authd for rights, like `AuthorizationCopyRights`, as a checked blocking call: it can wait for the
/// person to type a password.
///
/// - Parameters:
///   - authorization: The authorization.
///   - rights: The rights to ask for.
///   - environment: Extra data for the request (a prompt, an icon), or nil.
///   - flags: The options (`.interactionAllowed`, `.extendRights`).
///   - authorizedRights: Receives the rights given, or nil.
///   - fileID: The calling code's `#fileID` (names the call site).
///   - line: The calling code's `#line`.
/// - Returns: What `AuthorizationCopyRights` returns.
@inlinable
public func blockingAuthorizationCopyRights(
    _ authorization: AuthorizationRef, _ rights: UnsafePointer<AuthorizationRights>,
    _ environment: UnsafePointer<AuthorizationEnvironment>?, _ flags: AuthorizationFlags,
    _ authorizedRights: UnsafeMutablePointer<UnsafeMutablePointer<AuthorizationRights>?>?,
    fileID: StaticString = #fileID, line: UInt = #line
) -> OSStatus {
    // SAFETY: forwards the caller's pointers to AuthorizationCopyRights unchanged, only for the call; the caller's own
    // `unsafe` states why they are valid for it.
    return blockingCall(.systemCall, fileID: fileID, line: line) { unsafe AuthorizationCopyRights(authorization, rights, environment, flags, authorizedRights) }
}
