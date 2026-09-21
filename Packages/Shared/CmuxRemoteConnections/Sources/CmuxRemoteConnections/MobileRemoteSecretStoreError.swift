/// Failures from the local secret store, preserving security-relevant Keychain states.
public enum MobileRemoteSecretStoreError: Error, Equatable, Sendable {
    /// The Keychain access-group or service namespace is not an exact signed value.
    case invalidNamespace
    /// A scope contains an empty, oversized, or control-character account identifier.
    case invalidScope
    /// The localized reason is empty, oversized, or contains control characters.
    case invalidLocalizedReason
    /// The requested protection policy could not be represented by Security.framework.
    case invalidProtectionPolicy
    /// The caller attempted to add an item whose exact scoped identity already exists.
    case itemAlreadyExists
    /// The exact scoped item does not exist.
    case itemNotFound
    /// The device or Keychain is locked and the requested operation cannot continue.
    case deviceLocked(Int32)
    /// Security.framework requires user interaction that the request did not permit.
    case interactionNotAllowed(Int32)
    /// The user cancelled an authentication prompt.
    case userCancelled(Int32)
    /// The authentication supplied for the item was rejected.
    case authenticationFailed(Int32)
    /// The signed target lacks the configured Keychain access-group entitlement.
    case missingEntitlement(Int32)
    /// The item exists, but its returned value is not a byte payload.
    case corruptedItem(Int32)
    /// An unclassified Security.framework status, retained for diagnostics and policy.
    case keychainFailure(Int32)
}
