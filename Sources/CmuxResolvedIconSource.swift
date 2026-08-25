import AppKit

/// Describes an icon source that can be resolved by the shared AppKit renderer.
@MainActor
enum CmuxResolvedIconSource {
    /// An SF Symbol name resolved from the host SDK.
    case systemSymbol(name: String, accessibilityDescription: String?)
    /// An image from an asset catalog or bundle resource.
    case asset(name: String, bundle: Bundle)
    /// An already-created image that must be copied before drawing.
    case image(NSImage)
}
