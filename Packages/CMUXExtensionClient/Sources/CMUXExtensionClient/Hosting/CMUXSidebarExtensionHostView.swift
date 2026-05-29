import ExtensionFoundation
import ExtensionKit
import SwiftUI

@available(macOS 14.0, *)
/// SwiftUI bridge that hosts a sidebar extension scene through ExtensionKit.
public struct CMUXSidebarExtensionHostView: NSViewControllerRepresentable {
    public typealias NSViewControllerType = EXHostViewController

    /// Tracks the configuration currently installed on the host view controller.
    public final class Coordinator {
        fileprivate var currentKey: HostConfigurationKey?
    }

    fileprivate struct HostConfigurationKey: Equatable {
        var bundleIdentifier: String
        var sceneID: String
    }

    private let identity: AppExtensionIdentity
    private let sceneID: String

    /// Creates a sidebar extension host view.
    /// - Parameters:
    ///   - identity: Extension identity to host.
    ///   - sceneID: ExtensionKit scene identifier to render.
    public init(identity: AppExtensionIdentity, sceneID: String = CMUXSidebarExtensionPoint.defaultSceneID) {
        self.identity = identity
        self.sceneID = sceneID
    }

    /// Creates the configuration-tracking coordinator.
    /// - Returns: Coordinator for the hosted extension configuration.
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Creates the ExtensionKit host view controller.
    /// - Parameter context: SwiftUI representable context.
    /// - Returns: Configured `EXHostViewController`.
    public func makeNSViewController(context: Context) -> EXHostViewController {
        let viewController = EXHostViewController()
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

    private var configurationKey: HostConfigurationKey {
        HostConfigurationKey(bundleIdentifier: identity.bundleIdentifier, sceneID: sceneID)
    }
}
