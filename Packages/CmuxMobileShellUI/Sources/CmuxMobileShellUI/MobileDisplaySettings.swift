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

    /// Whether workspace-list row titles wrap onto multiple lines instead of
    /// truncating to a single line. Defaults to `false` (single-line). Mutating
    /// this writes through to the injected ``UserDefaults``.
    public var wrapWorkspaceTitles: Bool {
        didSet { defaults.set(wrapWorkspaceTitles, forKey: Self.wrapWorkspaceTitlesKey) }
    }

    /// Creates the display settings, seeding stored values from `defaults`.
    /// - Parameter defaults: The store backing the persisted preferences.
    ///   Defaults to `.standard`; tests pass a scoped suite. The stored property
    ///   is initialized from `defaults` and absent keys read as `false`, which
    ///   yields the single-line default without a write.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wrapWorkspaceTitles = defaults.bool(forKey: Self.wrapWorkspaceTitlesKey)
    }
}
