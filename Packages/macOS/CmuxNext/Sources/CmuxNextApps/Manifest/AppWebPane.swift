public import Foundation

/// An app pane drawn by a web page the app ships (`cmux.pane/1` with `web`).
///
/// The page runs in a WebKit content process on the shared page host under the strict page CSP,
/// served only from the directory that holds its entry inside the app's bundle
/// (plans/cmux-next/extensibility-DESIGN.md section 4).
public nonisolated struct AppWebPane: Sendable, Hashable {
    /// The `cmux.pane/1` implementation.
    public var implementation: AppImplementation
    /// The entry page, relative to the app bundle (`web/index.html`).
    public var entry: String

    /// - Parameters:
    ///   - implementation: The pane implementation that names the page.
    ///   - entry: The `web` value, relative to the app bundle.
    public init(implementation: AppImplementation, entry: String) {
        self.implementation = implementation
        self.entry = entry
    }

    /// The directory the page is served from: the entry's folder inside `bundle`. Nil when the
    /// entry is not an `index.html` or leaves the bundle (absolute, `.` or `..` components).
    public func root(in bundle: URL) -> URL? {
        nil
    }

    /// The page host for app `appID` (`cmux/codemirror` → `codemirror.cmux.apps`): reverse-DNS,
    /// never in the reserved `cmux.` namespace. Nil when the id is not `<publisher>/<name>` with
    /// lowercase letters, digits and `-` only.
    public static func pageHost(appID: String) -> String? {
        nil
    }
}
