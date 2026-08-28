public import Foundation

/// How a custom sidebar file should be rendered.
///
/// Custom sidebars began as interpreted SwiftUI (`.swift`) with a declarative `.json` variant.
/// Both describe a *render model* of rows and sections, which is the right shape for a list of
/// workspaces but cannot express an arbitrary interface. A web source covers that case: the file
/// names a page, and the sidebar hosts it.
public enum CustomSidebarSource: Equatable, Sendable {
    /// Interpreted SwiftUI or its declarative JSON form, rendered through the interpreter.
    case interpreted(URL)
    /// A page rendered in a web view: a local `.html` document, or the target of a `.url` file.
    case web(CustomSidebarWebSource)

    /// File extensions that resolve to an interpreted source, most preferred first.
    public static let interpretedFileExtensions = ["swift", "json"]

    /// File extensions that resolve to a web source, in the order the resolver prefers them.
    public static let webFileExtensions = ["html", "url"]

    /// Every recognised custom sidebar extension, in resolution order.
    ///
    /// Interpreted sources come first, so adding a `board.html` next to an existing `board.swift`
    /// never shadows the sidebar someone already uses. Every part of cmux that resolves a sidebar
    /// name to a file — the render path, the picker scan, and the CLI's `validate` / `reload` /
    /// `select` / `open` — orders by this one list, because a name that resolves differently
    /// depending on who asked is a bug the user experiences as "the CLI opened the wrong sidebar".
    public static let fileExtensions = interpretedFileExtensions + webFileExtensions

    /// Classifies an already-resolved custom sidebar file.
    ///
    /// Returns `nil` for an unrecognised extension or a `.url` file naming nothing loadable;
    /// callers treat that as "no sidebar" rather than guessing, so a stray file in the sidebars
    /// directory cannot render as something else.
    ///
    /// The extension is matched exactly, in lowercase. Case-folding it would be friendlier right
    /// here and wrong one step later: resolution builds `<name>.<ext>` from the lowercase list
    /// while discovery reads whatever is on disk, so a folded `board.HTML` is a file the CLI lists
    /// and then cannot open on a case-sensitive volume. Refusing it outright keeps every path in
    /// agreement on every filesystem.
    ///
    /// - Important: This reads the file for a `.url` source, so it blocks. A caller on the main
    ///   actor must go through ``classifying(fileURL:)`` instead.
    public static func classify(fileURL: URL) -> CustomSidebarSource? {
        switch classifyWithoutReading(fileURL: fileURL) {
        case let .decided(source):
            return source
        case let .needsURLFileRead(urlFileURL):
            guard let url = CustomSidebarWebSource.remoteURL(fromURLFile: urlFileURL) else { return nil }
            return .web(.remote(url))
        }
    }

    /// Classifies an already-resolved custom sidebar file without blocking.
    ///
    /// Same answer as ``classify(fileURL:)``, reached without holding up the caller: the `.url`
    /// branch is the only one that touches the filesystem, and this runs it off the caller's
    /// executor.
    ///
    /// `@concurrent` is what states that, rather than leaving it to inference. A nonisolated
    /// `async` function runs on the global executor today, but under the
    /// `NonisolatedNonsendingByDefault` upcoming feature it would instead inherit the caller's
    /// actor — so a main-actor caller would get the read back on the main thread, silently, on the
    /// day this module adopts that feature. The annotation pins the behaviour the callers depend on.
    ///
    /// - Parameter fileURL: The file the sidebar name resolved to.
    @concurrent
    public static func classifying(fileURL: URL) async -> CustomSidebarSource? {
        classify(fileURL: fileURL)
    }

    /// How far a file can be classified from its name alone.
    ///
    /// Every recognised extension except `.url` is decided by the extension: the file's *bytes*
    /// never change what it is. `.url` is the exception — it names a page, so the answer is inside
    /// it — and separating the two is what lets a caller that must not block (a SwiftUI `body`, the
    /// main actor) take the free answer immediately and defer only the read.
    public enum NonBlockingClassification: Equatable, Sendable {
        /// Decided from the extension. `nil` for an unrecognised one.
        case decided(CustomSidebarSource?)
        /// A `.url` file. The associated value is that file; reading it decides the source.
        case needsURLFileRead(URL)
    }

    /// Classifies as far as the extension allows, without touching the filesystem.
    ///
    /// - Parameter fileURL: The file the sidebar name resolved to.
    public static func classifyWithoutReading(fileURL: URL) -> NonBlockingClassification {
        switch fileURL.pathExtension {
        case "swift", "json":
            return .decided(.interpreted(fileURL))
        case "html":
            return .decided(.web(.document(fileURL)))
        case "url":
            return .needsURLFileRead(fileURL)
        default:
            return .decided(nil)
        }
    }
}
