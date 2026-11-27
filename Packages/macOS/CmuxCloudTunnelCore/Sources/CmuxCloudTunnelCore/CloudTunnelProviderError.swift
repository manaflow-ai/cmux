public import Foundation

/// Stable errors reported by the packet-tunnel extension to NetworkExtension.
public enum CloudTunnelProviderError: Int, Error, CustomNSError, Sendable {
    /// The saved configuration is absent.
    case missingConfiguration = 0
    /// The configuration schema is unsupported.
    case unsupportedSchema = 1
    /// WireGuard rejected the saved configuration.
    case invalidConfiguration = 2
    /// The tunnel's file descriptor was unavailable.
    case couldNotDetermineFileDescriptor = 3
    /// The peer endpoint could not be resolved.
    case dnsResolutionFailure = 4
    /// macOS rejected the network settings.
    case couldNotSetNetworkSettings = 5
    /// The WireGuard engine could not start.
    case couldNotStartBackend = 6
    /// The adapter rejected an operation in its current state.
    case invalidState = 7
    /// A stop superseded this start request.
    case cancelled = 8
    /// A replay supplied different configuration for a live adapter.
    case configurationChanged = 9

    /// Preserves the extension's error domain across the package extraction.
    public static var errorDomain: String { "cmuxTunnel.CloudTunnelProviderError" }
    /// The stable code delivered to macOS.
    public var errorCode: Int { rawValue }
}
