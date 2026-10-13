import Foundation

/// Stable identifiers for the legacy managed Cloud VM SSH attachment.
///
/// These values are persisted in workspace/session state and are therefore
/// compatibility identifiers, not a provider configuration surface. New
/// provisioning and attach metadata comes from the Cloud service; callers use
/// these only to recognize and migrate the existing managed slot.
public enum ManagedCloudVMConstants {
    public static let persistentDaemonSlot = "cmux-default-freestyle-sshd-v1"
    public static let legacyProviderID = "freestyle"
    public static let legacySSHDestinationSuffix = "+cmux@vm-ssh.freestyle.sh"
}
