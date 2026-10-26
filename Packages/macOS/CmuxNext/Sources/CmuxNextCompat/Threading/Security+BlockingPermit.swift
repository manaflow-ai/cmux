public import Security

/// ``blockingSecItemCopyMatching(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                                        _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecItemCopyMatching(query, result) }
}

/// ``blockingSecItemAdd(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                               _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecItemAdd(attributes, result) }
}

/// ``blockingSecItemUpdate(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary,
                                  _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecItemUpdate(query, attributesToUpdate) }
}

/// ``blockingSecItemDelete(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecItemDelete(_ query: CFDictionary, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecItemDelete(query) }
}

/// ``blockingSecTrustEvaluate(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecTrustEvaluate(_ trust: SecTrust, _ error: UnsafeMutablePointer<CFError?>?,
                                     _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecTrustEvaluateWithError(trust, error) }
}

/// ``blockingSecStaticCodeCheckValidity(_:_:_:errors:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecStaticCodeCheckValidity(_ code: SecStaticCode, _ flags: SecCSFlags, _ requirement: SecRequirement?,
                                               _ permit: borrowing BlockingPermit, errors: UnsafeMutablePointer<Unmanaged<CFError>?>? = nil,
                                               fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecStaticCodeCheckValidityWithErrors(code, flags, requirement, errors) }
}

/// ``blockingSecCodeCopySelf(_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecCodeCopySelf(_ flags: SecCSFlags, _ code: UnsafeMutablePointer<SecCode?>,
                                    _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecCodeCopySelf(flags, code) }
}

/// ``blockingSecCodeCopyStaticCode(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecCodeCopyStaticCode(_ code: SecCode, _ flags: SecCSFlags, _ staticCode: UnsafeMutablePointer<SecStaticCode?>,
                                          _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecCodeCopyStaticCode(code, flags, staticCode) }
}

/// ``blockingSecCodeCopySigningInformation(_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecCodeCopySigningInformation(_ code: SecStaticCode, _ flags: SecCSFlags,
                                                  _ information: UnsafeMutablePointer<CFDictionary?>,
                                                  _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecCodeCopySigningInformation(code, flags, information) }
}

/// ``blockingSecCodeCopyGuestWithAttributes(_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingSecCodeCopyGuestWithAttributes(_ host: SecCode?, _ attributes: CFDictionary?, _ flags: SecCSFlags,
                                                   _ guest: UnsafeMutablePointer<SecCode?>,
                                                   _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { SecCodeCopyGuestWithAttributes(host, attributes, flags, guest) }
}

/// ``blockingAuthorizationCopyRights(_:_:_:_:_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
@available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
@inlinable
public func blockingAuthorizationCopyRights(
    _ authorization: AuthorizationRef, _ rights: UnsafePointer<AuthorizationRights>,
    _ environment: UnsafePointer<AuthorizationEnvironment>?, _ flags: AuthorizationFlags,
    _ authorizedRights: UnsafeMutablePointer<UnsafeMutablePointer<AuthorizationRights>?>?,
    _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line
) -> OSStatus {
    return blockingCall(.systemCall, permit, fileID: fileID, line: line) { AuthorizationCopyRights(authorization, rights, environment, flags, authorizedRights) }
}
