import AppKit
public import Foundation

/// Opens previewed files in external applications and reveals them in Finder.
///
/// The `NSWorkspace` operations are constructor-injected `@Sendable` closures
/// (`openFile`, `openFileWithApplication`, `revealFile`) plus a `resolver` for
/// default/fallback selection, so the opener is testable without touching the
/// real workspace and holds no static `NSWorkspace` namespace. `live` wires the
/// closures to `NSWorkspace.shared`.
///
/// This folds the former `FileExternalOpenAction` caseless namespace-enum onto a
/// real value type with injected dependencies.
public struct FileExternalOpener: Sendable {
    /// Opens `fileURL` in its default handler; returns whether the open was
    /// dispatched.
    public var openFile: @Sendable (_ fileURL: URL) -> Bool
    /// Opens `fileURL` in the application at `applicationURL`.
    public var openFileWithApplication: @Sendable (_ fileURL: URL, _ applicationURL: URL) -> Void
    /// Selects `fileURL` in a Finder window.
    public var revealFile: @Sendable (_ fileURL: URL) -> Void
    /// Resolver used to pick the default/fallback application for `openDefault`.
    public var resolver: FileExternalOpenApplicationResolver

    /// Creates an opener from its injected workspace operations and resolver.
    public init(
        openFile: @escaping @Sendable (_ fileURL: URL) -> Bool,
        openFileWithApplication: @escaping @Sendable (_ fileURL: URL, _ applicationURL: URL) -> Void,
        revealFile: @escaping @Sendable (_ fileURL: URL) -> Void,
        resolver: FileExternalOpenApplicationResolver
    ) {
        self.openFile = openFile
        self.openFileWithApplication = openFileWithApplication
        self.revealFile = revealFile
        self.resolver = resolver
    }

    /// The production opener backed by `NSWorkspace.shared` and the live
    /// resolver. The open configuration disables new application instances to
    /// match the legacy behavior.
    public static let live = FileExternalOpener(
        openFile: { NSWorkspace.shared.open($0) },
        openFileWithApplication: { fileURL, applicationURL in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration)
        },
        revealFile: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        resolver: .live
    )

    /// Opens `fileURL` in its default eligible application, falling back to the
    /// first eligible candidate when the system default is filtered out (cmux
    /// itself). Returns whether an open was dispatched.
    @discardableResult
    public func openDefault(fileURL: URL) -> Bool {
        guard let defaultURL = resolver.defaultApplicationURL(fileURL) else {
            return openFile(fileURL)
        }
        if resolver.shouldIncludeApplication(defaultURL) {
            openFileWithApplication(fileURL, defaultURL)
            return true
        }
        let fallbackURL = resolver.applicationURLs(fileURL).first(where: resolver.shouldIncludeApplication)
        guard let fallbackURL else { return false }
        openFileWithApplication(fileURL, fallbackURL)
        return true
    }

    /// Opens `fileURL` in `applicationURL` when provided, otherwise in the
    /// system default handler. Returns whether an open was dispatched.
    @discardableResult
    public func open(fileURL: URL, applicationURL: URL?) -> Bool {
        if let applicationURL {
            openFileWithApplication(fileURL, applicationURL)
            return true
        }
        return openFile(fileURL)
    }

    /// Reveals `fileURL` in Finder.
    public func revealInFinder(fileURL: URL) {
        revealFile(fileURL)
    }
}
