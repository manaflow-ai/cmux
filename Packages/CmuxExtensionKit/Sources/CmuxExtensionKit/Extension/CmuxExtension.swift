@_exported import ExtensionFoundation
@_exported import ExtensionKit
import Foundation

/// Base protocol for all CMUX extensions.
///
/// Conform to a concrete CMUX extension protocol, such as
/// `CmuxSidebarExtension`, from your `@main` app extension type. CMUX extension
/// protocols refine `AppExtension`, so the SDK owns ExtensionKit configuration
/// and extension-point binding while your extension provides its manifest and UI.
@MainActor
public protocol CmuxExtension: AppExtension, AnyObject where Configuration == AppExtensionSceneConfiguration {
    /// Manifest describing this extension and the data/actions it requests.
    static var manifest: CMUXExtensionManifest { get }
}
