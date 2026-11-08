/// The data-protection policy applied to an Iroh capability in Keychain.
public enum CmxIrohSecureCredentialAccessibility: Equatable, Sendable {
    /// Available after the first device unlock and excluded from migration to another device.
    case afterFirstUnlockThisDeviceOnly
}
