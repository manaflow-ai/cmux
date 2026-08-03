@_exported import ExtensionFoundation
import Foundation

/// Current state of the connection between a sidebar extension and cmux.
public enum CmuxSidebarConnectionStatus: Equatable, Sendable {
    case connected
    case waitingForHost
    case error(String)
}

/// A UI-less sidebar app extension whose value tree is rendered by cmux.
///
/// Conform from the extension's `@main` type. The SDK supplies the extension
/// configuration and XPC transport. The extension supplies its manifest,
/// current presentation, snapshot handling, and action handling.
@MainActor
public protocol CmuxSidebarExtension: AppExtension, AnyObject
where Configuration == CmuxSidebarExtensionConfiguration {
    static var manifest: CmuxExtensionManifest { get }

    /// Current value-only native presentation sent to the host.
    var presentation: CmuxSidebarPresentation { get }

    /// Called whenever cmux sends a filtered sidebar snapshot.
    func update(context: CmuxSidebarContext)

    /// Called when the cmux host connection changes state.
    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus)

    /// Handles a button identifier emitted by ``presentation``.
    func handlePresentationAction(_ id: String) async
}

public extension CmuxSidebarExtension {
    var configuration: CmuxSidebarExtensionConfiguration {
        let runtime = CmuxSidebarExtensionRuntime(sidebarExtension: self)
        return CmuxSidebarExtensionConfiguration { connection in
            runtime.accept(connection)
        }
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {}
    func handlePresentationAction(_ id: String) async {}
}

/// Connection-only configuration usable on every cmux-supported macOS version.
public struct CmuxSidebarExtensionConfiguration: AppExtensionConfiguration, Sendable {
    private let acceptConnection: @Sendable (NSXPCConnection) -> Bool

    init(acceptConnection: @escaping @Sendable (NSXPCConnection) -> Bool) {
        self.acceptConnection = acceptConnection
    }

    nonisolated public func accept(connection: NSXPCConnection) -> Bool {
        acceptConnection(connection)
    }
}
