import CMUXMobileCore
import CmuxMobileShell
import SwiftUI

/// Composition-root factory for a dedicated diff-viewer RPC connection.
public struct MobileDiffRPCClientFactory: Sendable {
    private let makeClient: @Sendable (CmxAttachRoute, CmxAttachTicket) -> any MobileSyncing

    /// Creates a factory from the app's runtime-aware client builder.
    /// - Parameter makeClient: Builds a client for the current route and ticket.
    public init(
        makeClient: @escaping @Sendable (CmxAttachRoute, CmxAttachTicket) -> any MobileSyncing
    ) {
        self.makeClient = makeClient
    }

    /// Builds an isolated client for one diff-viewer presentation.
    /// - Parameters:
    ///   - route: The active paired-Mac route.
    ///   - ticket: The active attach ticket.
    /// - Returns: A request client owned by the diff viewer.
    public func client(route: CmxAttachRoute, ticket: CmxAttachTicket) -> any MobileSyncing {
        makeClient(route, ticket)
    }
}

private struct MobileDiffRPCClientFactoryEnvironmentKey: EnvironmentKey {
    static let defaultValue: MobileDiffRPCClientFactory? = nil
}

public extension EnvironmentValues {
    /// Factory injected by the iOS composition root for native diff requests.
    var mobileDiffRPCClientFactory: MobileDiffRPCClientFactory? {
        get { self[MobileDiffRPCClientFactoryEnvironmentKey.self] }
        set { self[MobileDiffRPCClientFactoryEnvironmentKey.self] = newValue }
    }
}
