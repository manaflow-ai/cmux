public import Foundation

/// The pure title-selection policy for the workspace a detached surface becomes
/// when a tab is moved out into its own new workspace.
///
/// Moving a surface to a new workspace (the "move tab to new workspace" drop and
/// its sibling cross-window move) must title the destination workspace. The
/// legacy app-target logic on `AppDelegate` resolved that title by preferring an
/// explicit caller-supplied title, then the surface's own title, and finally a
/// localized "Tab" fallback. The string SOURCES are app-target state: the
/// explicit title is a command parameter, the surface title comes from the
/// `Workspace`/`Panel` (app types), and the localized fallback must be resolved
/// in the app bundle so non-English (Japanese) translations are not dropped (a
/// `String(localized:)` call inside a package binds to the package bundle, which
/// lacks the keys). So the app shim resolves those three strings and hands them
/// to this policy, which owns only the irreducible *decision*: which of the
/// candidate strings, after trimming whitespace, becomes the title.
///
/// This is a `Sendable` value type with one pure method and no stored state of
/// its own beyond the candidate inputs passed per call, so it is trivially
/// unit-testable and carries no app coupling. It deliberately does NOT name
/// `Workspace`/`Panel`/`AppDelegate`; lifting only the decision keeps the
/// app-coupled resolution as the thin app-side shim over this policy, matching
/// the windowing de-aggregation discipline (per-window/move logic is domain
/// policy here, the live-state reach stays app-side).
public struct DetachedWorkspaceTitlePolicy: Sendable, Equatable {
    /// Creates the policy. It is stateless; the app constructs one wherever it
    /// resolves a detached-workspace title.
    public init() {}

    /// Selects the destination workspace title from already-resolved candidates.
    ///
    /// - Parameters:
    ///   - explicitTitle: The caller-supplied title, if any (e.g. a command
    ///     parameter). Used verbatim (after trimming) when it is non-empty.
    ///   - surfaceTitle: The surface's own title, resolved app-side from the
    ///     `Workspace`/`Panel`. Used (after trimming) when no usable explicit
    ///     title exists.
    ///   - localizedFallback: The localized "Tab" fallback, resolved in the app
    ///     bundle, returned when neither candidate trims to a non-empty string.
    /// - Returns: The first of `explicitTitle` then `surfaceTitle` whose
    ///   whitespace-and-newline-trimmed form is non-empty, otherwise
    ///   `localizedFallback`.
    public func title(
        explicitTitle: String?,
        surfaceTitle: String,
        localizedFallback: String
    ) -> String {
        if let trimmedExplicit = explicitTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedExplicit.isEmpty {
            return trimmedExplicit
        }

        let trimmedSurfaceTitle = surfaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSurfaceTitle.isEmpty {
            return trimmedSurfaceTitle
        }

        return localizedFallback
    }
}
