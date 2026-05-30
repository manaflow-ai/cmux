import SwiftUI

/// A SwiftUI sidebar extension hosted by CMUX.
///
/// Conform to this protocol from your `@main` app extension type. The SDK
/// supplies the ExtensionKit configuration, scene, and XPC wiring. Your
/// extension supplies the manifest, SwiftUI body, and snapshot update handling.
@MainActor
public protocol CmuxSidebarExtension: CmuxUIExtension {
    /// Called whenever CMUX sends a new filtered sidebar snapshot.
    func update(context: CmuxSidebarContext)

    /// Called when the CMUX host connection changes state or reports an error.
    func connectionErrorDidChange(_ message: String?)
}

public extension CmuxSidebarExtension {
    /// ExtensionKit configuration for the CMUX sidebar extension point.
    ///
    /// Extension authors should not implement this unless they are deliberately
    /// replacing the SDK's ExtensionKit scene wiring.
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(CmuxSidebarExtensionScene(self))
    }

    func connectionErrorDidChange(_ message: String?) {}
}
