public import ExtensionFoundation
public import ExtensionKit
@_spi(CmuxHostTransport) public import CmuxExtensionKit
public import Foundation
public import SwiftUI

@available(macOS 14.0, *)
/// SwiftUI bridge that hosts a sidebar extension scene through ExtensionKit.
@_spi(CmuxHostTransport) public struct CMUXSidebarExtensionHostView: NSViewControllerRepresentable {
    public typealias NSViewControllerType = EXHostViewController

    /// Tracks the configuration currently installed on the host view controller.
    @_spi(CmuxHostTransport) public final class Coordinator: NSObject, EXHostViewControllerDelegate {
        fileprivate var currentKey: HostConfigurationKey?
        private let onConnection: (@MainActor (NSXPCConnection) -> Void)?
        private let onDeactivation: (@MainActor ((any Error)?) -> Void)?
        private let onTeardown: (@MainActor () -> Void)?

        fileprivate init(
            onConnection: (@MainActor (NSXPCConnection) -> Void)?,
            onDeactivation: (@MainActor ((any Error)?) -> Void)?,
            onTeardown: (@MainActor () -> Void)?
        ) {
            self.onConnection = onConnection
            self.onDeactivation = onDeactivation
            self.onTeardown = onTeardown
        }

        public func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            guard let onConnection else { return }
            do {
                onConnection(try viewController.makeXPCConnection())
            } catch {
                onDeactivation?(error)
            }
        }

        public func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: (any Error)?) {
            onDeactivation?(error)
        }

        @MainActor
        fileprivate func teardown() {
            onTeardown?()
        }
    }

    fileprivate struct HostConfigurationKey: Equatable {
        var bundleIdentifier: String
        var sceneID: String
    }

    private let identity: AppExtensionIdentity
    private let sceneID: String
    private let onConnection: (@MainActor (NSXPCConnection) -> Void)?
    private let onDeactivation: (@MainActor ((any Error)?) -> Void)?
    private let onTeardown: (@MainActor () -> Void)?

    /// Creates a sidebar extension host view.
    /// - Parameters:
    ///   - identity: Extension identity to host.
    ///   - sceneID: ExtensionKit scene identifier to render.
    public init(
        identity: AppExtensionIdentity,
        sceneID: String = CmuxSidebarExtensionPoint.defaultSceneID,
        onConnection: (@MainActor (NSXPCConnection) -> Void)? = nil,
        onDeactivation: (@MainActor ((any Error)?) -> Void)? = nil,
        onTeardown: (@MainActor () -> Void)? = nil
    ) {
        self.identity = identity
        self.sceneID = sceneID
        self.onConnection = onConnection
        self.onDeactivation = onDeactivation
        self.onTeardown = onTeardown
    }

    /// Creates the configuration-tracking coordinator.
    /// - Returns: Coordinator for the hosted extension configuration.
    public func makeCoordinator() -> Coordinator {
        Coordinator(onConnection: onConnection, onDeactivation: onDeactivation, onTeardown: onTeardown)
    }

    /// Creates the ExtensionKit host view controller.
    /// - Parameter context: SwiftUI representable context.
    /// - Returns: Configured `EXHostViewController`.
    public func makeNSViewController(context: Context) -> EXHostViewController {
        let viewController = EXHostViewController()
        viewController.delegate = context.coordinator
        context.coordinator.currentKey = configurationKey
        viewController.configuration = EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: sceneID
        )
        return viewController
    }

    /// Updates the host view controller when the hosted extension changes.
    /// - Parameters:
    ///   - viewController: Existing ExtensionKit host view controller.
    ///   - context: SwiftUI representable context.
    public func updateNSViewController(_ viewController: EXHostViewController, context: Context) {
        guard context.coordinator.currentKey != configurationKey else { return }
        context.coordinator.currentKey = configurationKey
        viewController.configuration = EXHostViewController.Configuration(
            appExtension: identity,
            sceneID: sceneID
        )
    }

    public static func dismantleNSViewController(_ viewController: EXHostViewController, coordinator: Coordinator) {
        coordinator.teardown()
        coordinator.currentKey = nil
        viewController.delegate = nil
        viewController.configuration = nil
    }

    private var configurationKey: HostConfigurationKey {
        HostConfigurationKey(bundleIdentifier: identity.bundleIdentifier, sceneID: sceneID)
    }
}
