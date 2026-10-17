import Foundation

/// One name's ``CloudSecretMachineState`` on a machine.
public struct CloudSecretMachineStatusRow: Hashable, Sendable {
    public let name: String
    /// The winning scope, `nil` for ``CloudSecretMachineState/extra`` rows.
    public let scope: CloudSecretScope?
    public let state: CloudSecretMachineState
    /// The vault's fingerprint, or the delivered one for an extra row.
    public let fingerprint: String?

    public init(name: String, scope: CloudSecretScope?, state: CloudSecretMachineState, fingerprint: String?) {
        self.name = name
        self.scope = scope
        self.state = state
        self.fingerprint = fingerprint
    }
}
