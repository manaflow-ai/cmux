public import Foundation

/// Partitions the file URLs and directories of an external deep-link open
/// intent into the ordered ``DeepLinkOpenPlan`` the app target executes.
///
/// This is the seam for the URL-partitioning half of AppDelegate's
/// `application(_:open:)`. The app target owns the AppKit-facing entry point,
/// the auth-callback handling, the cmux-scheme route handling, and the live
/// window/workspace routing; it depends on this seam so the pure step
/// (splitting the already-classified external file URLs into terminal-eligible
/// requests versus preview paths, alongside the directories) lives in the
/// windowing domain and can be exercised with injected inputs. Production uses
/// ``DeepLinkOpenPlanner``; tests inject a fake.
///
/// The directory and file-versus-directory classification (self-bundle
/// exclusion, dedupe) happens before this seam, in the app target's external
/// open URL classifier; this seam only takes the resulting file URLs and
/// directory paths and decides which files run in a terminal.
///
/// The partitioning is pure URL string work with no main-bound dependency, so
/// the seam is `Sendable` and `nonisolated` (the production
/// ``DeepLinkOpenPlanner`` is a `Sendable` value); the app target calls it from
/// its `@MainActor` deep-link entry without a hop.
public protocol DeepLinkRouting: Sendable {
    /// Builds the open plan from the classified external open inputs.
    /// - Parameters:
    ///   - externalFileURLs: The non-directory file URLs to open, already
    ///     filtered to exclude directories and the running app bundle, in
    ///     input order.
    ///   - directories: The ordered, de-duplicated directories to open as
    ///     workspaces.
    /// - Returns: The plan partitioning `externalFileURLs` into terminal
    ///   requests and preview paths, carrying `directories` through unchanged.
    func openPlan(
        externalFileURLs: [URL],
        directories: [String]
    ) -> DeepLinkOpenPlan
}
