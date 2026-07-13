internal import Foundation

/// Connection identity of a BYO VPS host: the SSH destination plus the
/// transport parameters cmux passes straight to OpenSSH.
///
/// Auth is deliberately absent: provisioning rides the user's existing SSH
/// configuration (ssh config, agent, identity files). cmux never stores or
/// transmits private keys.
public struct VPSHostDescriptor: Equatable, Sendable, Codable {
    /// SSH destination in OpenSSH syntax (`user@host` or a `~/.ssh/config` alias).
    public var destination: String
    /// Explicit SSH port, or `nil` to defer to ssh config / the default port.
    public var port: Int?
    /// Explicit identity file path (`ssh -i`), or `nil` to defer to ssh config.
    public var identityFile: String?
    /// Extra `-o` options passed verbatim to every ssh/scp invocation.
    public var sshOptions: [String]

    /// Creates a host descriptor.
    ///
    /// - Parameters:
    ///   - destination: SSH destination (`user@host` or config alias).
    ///   - port: Explicit port, or `nil` for ssh defaults.
    ///   - identityFile: Explicit identity file, or `nil` for ssh defaults.
    ///   - sshOptions: Extra `-o` options, defaults to none.
    public init(
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        sshOptions: [String] = []
    ) {
        self.destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
    }

    /// Stable registry key for this host: the destination plus the explicit
    /// port when present (`user@host` or `user@host:2222`).
    ///
    /// Two descriptors that differ only in identity file or ssh options refer
    /// to the same provisioned host, so they share a key.
    public var registryKey: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }
}
