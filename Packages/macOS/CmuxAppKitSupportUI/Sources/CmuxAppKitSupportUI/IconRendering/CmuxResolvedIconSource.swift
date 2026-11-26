public import AppKit
public import Foundation
public import UniformTypeIdentifiers

/// Source image for a small cmux UI icon that must be resolved through AppKit.
@MainActor
public enum CmuxResolvedIconSource {
    /// An SF Symbol resolved through `NSImage(systemSymbolName:accessibilityDescription:)`.
    case systemSymbol(name: String, accessibilityDescription: String?)
    /// An asset-catalog image resolved from a bundle.
    case asset(name: String, bundle: Bundle)
    /// An already-created image. The renderer copies it before sizing or drawing.
    case image(NSImage)
    /// A Finder/system image resolved by `NSWorkspace` for a Uniform Type.
    ///
    /// Resolving this source inside the renderer keeps the workspace image out
    /// of SwiftUI's view construction and gives the image view a stable source
    /// identity without sharing a mutable `NSImage` singleton.
    case workspaceIcon(UTType)
}
