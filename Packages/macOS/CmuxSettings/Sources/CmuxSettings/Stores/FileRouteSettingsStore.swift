import Foundation

/// Repository for the cmd-click file routing settings, persisted in
/// `UserDefaults` under the catalog's `app.openMarkdownInCmuxViewer` and
/// `app.openSupportedFilesInCmux` keys.
///
/// Writes post ``markdownRouteDidChange`` / ``supportedFileRouteDidChange``
/// so already-rendered terminal link affordances refresh. The notification
/// names are kept verbatim from the legacy settings namespaces; retiring
/// them for `AsyncStream` change feeds is a later modernization once their
/// observers move into packages.
///
/// Isolation: a stateless `Sendable` struct, not an actor. `shouldRoute*` is
/// deliberately callable off the main thread (the cmd-click path filters
/// before any UI hop), the struct holds no mutable state, and
/// `UserDefaults`, `FileManager`, and `NotificationCenter` are documented
/// thread-safe.
public struct FileRouteSettingsStore: FileRouteSettingsReading {
    /// Posted after the markdown route toggle changes.
    public static let markdownRouteDidChange = Notification.Name("cmux.cmdClickMarkdownRouteDidChange")

    /// Posted after the supported-file route toggle changes.
    public static let supportedFileRouteDidChange = Notification.Name("cmux.cmdClickSupportedFileRouteDidChange")

    // UserDefaults, FileManager, and NotificationCenter are documented
    // thread-safe and the references are immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private nonisolated(unsafe) let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let keys = AppCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    ///
    /// - Parameters:
    ///   - defaults: The defaults suite holding the route toggles.
    ///   - fileManager: Probes routed paths; tests pass a scoped instance.
    ///   - notificationCenter: Receives the did-change posts.
    public init(
        defaults: UserDefaults,
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
    }

    public var markdownRouteEnabled: Bool {
        keys.openMarkdownInCmuxViewer.value(in: defaults)
    }

    public var supportedFileRouteEnabled: Bool {
        keys.openSupportedFilesInCmux.value(in: defaults)
    }

    /// Enables or disables the markdown route and posts
    /// ``markdownRouteDidChange``.
    public func setMarkdownRouteEnabled(_ enabled: Bool) {
        keys.openMarkdownInCmuxViewer.set(enabled, in: defaults)
        notifyMarkdownRouteDidChange()
    }

    /// Enables or disables the supported-file route and posts
    /// ``supportedFileRouteDidChange``.
    public func setSupportedFileRouteEnabled(_ enabled: Bool) {
        keys.openSupportedFilesInCmux.set(enabled, in: defaults)
        notifySupportedFileRouteDidChange()
    }

    /// Posts ``markdownRouteDidChange`` without writing, for callers that
    /// mutate the underlying default through another path.
    public func notifyMarkdownRouteDidChange() {
        notificationCenter.post(name: Self.markdownRouteDidChange, object: nil)
    }

    /// Posts ``supportedFileRouteDidChange`` without writing, for callers
    /// that mutate the underlying default through another path.
    public func notifySupportedFileRouteDidChange() {
        notificationCenter.post(name: Self.supportedFileRouteDidChange, object: nil)
    }

    public func shouldRouteMarkdown(path: String) -> Bool {
        guard markdownRouteEnabled, Self.isMarkdownPath(path) else { return false }
        // Match the `markdown.open` socket path: only route real, readable
        // files. Rejects FIFOs, device nodes, sockets, symlinks to
        // non-regular targets, and permission-denied paths so the viewer
        // never opens into an unavailable state.
        return isReadableRegularFile(path: path)
    }

    public func shouldRouteSupportedFile(path: String) -> Bool {
        guard supportedFileRouteEnabled else { return false }
        return isReadableRegularFile(path: path)
    }

    /// Cheap extension check. Safe to call off the main thread before any
    /// filesystem probe so remote/non-markdown paths can be filtered early.
    public static func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "mkd" || ext == "mdx"
    }

    /// Whether `path` (after resolving symlinks) is a readable regular file.
    public func isReadableRegularFile(path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard fileManager.isReadableFile(atPath: resolved),
              let attrs = try? fileManager.attributesOfItem(atPath: resolved),
              (attrs[.type] as? FileAttributeType) == .typeRegular else {
            return false
        }
        return true
    }
}
