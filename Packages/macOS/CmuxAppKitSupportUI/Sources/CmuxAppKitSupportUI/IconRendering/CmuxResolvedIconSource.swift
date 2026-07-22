public import AppKit
public import Foundation

/// Source image for a small cmux UI icon that must be resolved through AppKit.
@MainActor
public enum CmuxResolvedIconSource {
    /// An SF Symbol resolved through `NSImage(systemSymbolName:accessibilityDescription:)`.
    case systemSymbol(name: String, accessibilityDescription: String?)
    /// An asset-catalog image resolved from a bundle.
    case asset(name: String, bundle: Bundle)
    /// An already-created image. The renderer copies it before sizing or drawing.
    case image(NSImage)
}
