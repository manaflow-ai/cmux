import Foundation

/// Stable identifiers for the legacy managed Cloud VM SSH attachment.
///
/// These values are persisted in workspace/session state and are therefore
/// compatibility identifiers, not a provider configuration surface. New
/// provisioning and attach metadata comes from the Cloud service; callers use
/// these only to recognize and migrate the existing managed slot.
public enum ManagedCloudVMConstants {
    /// The persisted slot name used by the original managed Cloud VM SSH flow.
    public static let persistentDaemonSlot = "cmux-default-freestyle-sshd-v1"
    /// The provider identifier retained when decoding legacy managed VM state.
    public static let legacyProviderID = "freestyle"
    /// The legacy SSH destination suffix used to recover a VM id from a snapshot.
    public static let legacySSHDestinationSuffix = "+cmux@vm-ssh.freestyle.sh"
}
