public import Foundation

/// Classifies file URLs that arrive from an external open intent (the
/// `application(_:open:)` deep-link entry and the Finder NSServices
/// `openWindow`/`openTab` handlers) into the directories and files cmux
/// should act on.
///
/// The app target's deep-link/services shims own the AppKit-facing entry
/// points and the live-window routing; they depend on this seam instead of
/// the concrete ``ExternalOpenURLClassifier`` so the pure URL-shaping rules
/// (self-bundle exclusion, directory detection, dedupe) live in the domain
/// package and can be exercised with injected inputs.
public protocol ExternalOpenURLClassifying: Sendable {
    /// Resolves the ordered, de-duplicated directories to open from `urls`,
    /// dropping any path inside the running app bundle (LaunchServices can
    /// surface the running bundle on relaunch).
    func directories(from urls: [URL]) -> [String]

    /// Resolves the ordered, de-duplicated non-directory file URLs to open
    /// from `urls`, dropping directories and any path inside the running app
    /// bundle.
    func fileURLs(from urls: [URL]) -> [URL]

    /// Reports whether `url` refers to a directory on disk.
    func isDirectory(_ url: URL) -> Bool
}
