@_exported import ExtensionFoundation
@_exported import ExtensionKit
import SwiftUI

/// Current state of the connection between a sidebar extension and CMUX.
public enum CmuxSidebarConnectionStatus: Equatable, Sendable {
    /// The extension is connected and receiving host updates.
    case connected

    /// The extension has no active CMUX host connection yet.
    case waitingForHost

    /// The host connection reported an error message suitable for diagnostics.
    case error(String)
}

/// A SwiftUI sidebar extension hosted by CMUX.
///
/// Conform to this protocol from your `@main` app extension type. The SDK
/// supplies the ExtensionKit configuration, scene, and XPC wiring. Your
/// extension supplies the manifest, SwiftUI body, and snapshot update handling.
@MainActor
public protocol CmuxSidebarExtension: AppExtension, AnyObject where Configuration == AppExtensionSceneConfiguration {
    /// Manifest describing this sidebar extension and the data/actions it requests.
    static var manifest: CmuxExtensionManifest { get }

    /// SwiftUI content rendered inside the extension scene.
    associatedtype Body: View

    /// The view CMUX hosts for this extension.
    @ViewBuilder var body: Body { get }

    /// Called whenever CMUX sends a new filtered sidebar snapshot.
    func update(context: CmuxSidebarContext)

    /// Called when the CMUX host connection changes state or reports an error.
    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus)

}

public extension CmuxSidebarExtension {
    /// ExtensionKit configuration for the CMUX sidebar extension point.
    ///
    /// Extension authors should not implement this unless they are deliberately
    /// replacing the SDK's ExtensionKit scene wiring.
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(CmuxSidebarExtensionScene(self))
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {}
}
