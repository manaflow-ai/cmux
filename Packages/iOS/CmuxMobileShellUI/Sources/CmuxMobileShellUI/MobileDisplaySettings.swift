import Foundation
import Observation

/// User-tunable display preferences for the mobile workspace UI, persisted to an
/// injected ``UserDefaults``.
///
/// Constructed once at the app composition root and injected into the SwiftUI
/// environment (no singleton). Views read it through `@Environment` and bind to
/// it with `@Bindable`; the `@Observable` conformance drives re-renders when a
/// preference changes. The backing store is injected so tests pass a scoped
/// `UserDefaults(suiteName:)` instead of polluting `.standard`.
///
/// ```swift
/// let settings = MobileDisplaySettings(defaults: UserDefaults(suiteName: "test")!)
/// settings.wrapWorkspaceTitles = true // persisted to the injected defaults
/// ```
@MainActor
@Observable
public final class MobileDisplaySettings {
    // UserDefaults is Apple-documented thread-safe; the synchronous read in
    // `init` and the write-through in `didSet` are safe nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let wrapWorkspaceTitlesKey = "cmux.mobile.wrapWorkspaceTitles"
    private static let workspacePreviewLineCountKey = "cmux.mobile.workspacePreviewLineCount"

    /// The preview line counts the "Preview Lines" setting offers.
    public static let workspacePreviewLineCountRange = 1...2
    /// Default preview line count when nothing is stored (iMessage-style two
    /// lines).
    public static let defaultWorkspacePreviewLineCount = 2

    /// Whether workspace-list row titles wrap onto multiple lines instead of
    /// truncating to a single line. Defaults to `false` (single-line). Mutating
    /// this writes through to the injected ``UserDefaults``.
    public var wrapWorkspaceTitles: Bool {
        didSet { defaults.set(wrapWorkspaceTitles, forKey: Self.wrapWorkspaceTitlesKey) }
    }

    /// How many lines a workspace row's activity preview shows (1 or 2).
    /// Defaults to 2. Mutating this clamps to the supported range and writes
    /// through to the injected ``UserDefaults``.
    public var workspacePreviewLineCount: Int {
        didSet {
            let clamped = Self.clampedWorkspacePreviewLineCount(workspacePreviewLineCount)
            // Assigning inside didSet does not re-trigger the observer.
            if clamped != workspacePreviewLineCount { workspacePreviewLineCount = clamped }
            defaults.set(clamped, forKey: Self.workspacePreviewLineCountKey)
        }
    }

    /// Creates the display settings, seeding stored values from `defaults`.
    /// - Parameter defaults: The store backing the persisted preferences.
    ///   Defaults to `.standard`; tests pass a scoped suite. Stored properties
    ///   are initialized from `defaults`; absent keys read as their default
    ///   (single-line titles, two preview lines) without a write.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wrapWorkspaceTitles = defaults.bool(forKey: Self.wrapWorkspaceTitlesKey)
        let storedPreviewLines = defaults.object(forKey: Self.workspacePreviewLineCountKey) as? Int
        self.workspacePreviewLineCount = Self.clampedWorkspacePreviewLineCount(
            storedPreviewLines ?? Self.defaultWorkspacePreviewLineCount
        )
    }

    /// Clamps a stored or assigned preview line count to the supported range.
    /// A static member (not a file-scope func) because the package-conventions
    /// linter forbids free functions in the mobile packages.
    private static func clampedWorkspacePreviewLineCount(_ count: Int) -> Int {
        min(
            max(count, workspacePreviewLineCountRange.lowerBound),
            workspacePreviewLineCountRange.upperBound
        )
    }
}
