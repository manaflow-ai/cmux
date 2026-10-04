import Foundation

/// Where and how to reach the browser host's provider listener. The daemon
/// mints the secret and gives it to the app over its own daemon connection
/// (`browser.host.provider`, step c2); it is never read from a file, argv or
/// the environment.
public nonisolated struct ProviderCredentials: Hashable, Sendable {
    public var socketPath: String
    public var secret: ProviderSecret

    public init(socketPath: String, secret: ProviderSecret) {
        self.socketPath = socketPath
        self.secret = secret
    }
}

/// The app's provider identity in `hello`.
public nonisolated struct ProviderIdentity: Hashable, Sendable {
    public var providerID: String
    /// One app per install: the host refuses a second provider with it.
    public var installID: String
    public var engines: [String]

    public init(providerID: String, installID: String, engines: [String] = ["webkit", "cef"]) {
        self.providerID = providerID
        self.installID = installID
        self.engines = engines
    }
}

public nonisolated enum ProviderEngine: String, Hashable, Sendable {
    case webkit, cef
}
