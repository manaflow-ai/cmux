public import Foundation
import AppKit

/// Performs the actual `NSWorkspace` open/reveal operations for a file, using an
/// injected ``FileExternalOpenApplicationResolver`` to pick the default app and
/// its fallbacks. A value type holding its resolver (`.live` is the shared
/// production instance) rather than a static-only namespace.
public struct FileExternalOpenAction: Sendable {
    private let resolver: FileExternalOpenApplicationResolver

    public init(resolver: FileExternalOpenApplicationResolver = .live) {
        self.resolver = resolver
    }

    /// The production action backed by ``FileExternalOpenApplicationResolver/live``.
    public static let live = FileExternalOpenAction()

    @discardableResult
    public func openDefault(fileURL: URL) -> Bool {
        guard let defaultURL = resolver.defaultApplicationURL(fileURL) else {
            return open(fileURL: fileURL, applicationURL: nil)
        }
        if resolver.shouldIncludeApplication(defaultURL) {
            return open(fileURL: fileURL, applicationURL: defaultURL)
        }
        let fallbackURL = resolver.applicationURLs(fileURL).first(where: resolver.shouldIncludeApplication)
        guard let fallbackURL else { return false }
        return open(fileURL: fileURL, applicationURL: fallbackURL)
    }

    @discardableResult
    public func open(fileURL: URL, applicationURL: URL?) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        if let applicationURL {
            NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
        return NSWorkspace.shared.open(fileURL)
    }

    public func revealInFinder(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
