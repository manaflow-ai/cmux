import Observation

/// The mutable owner of the active Aurean appearance, created once and injected at the app root.
///
/// ``AureanTheme`` holds the selected ``AureanPaletteVariant`` and resolves it to a concrete
/// ``AureanPalette``. It is the single writable seam for re-skinning the app: flipping
/// ``variant`` notifies every observer (SwiftUI re-renders, `withObservationTracking` fires),
/// because the type is `@Observable`.
///
/// Construct it at the app's startup site and inject it with
/// ``SwiftUI/View/aureanTheme(_:)`` — there is no shared/`default` instance, so tests
/// instantiate a fresh, isolated owner. Views read colors through
/// `@Environment(\.aureanPalette)` and reach back to this owner (to switch temperature)
/// through `@Environment(AureanTheme.self)`.
///
/// ```swift
/// @State private var theme = AureanTheme(variant: .cool)
/// var body: some Scene {
///     WindowGroup { ContentView().aureanTheme(theme) }
/// }
/// ```
@Observable
@MainActor
public final class AureanTheme {
    /// The active temperature. Mutating this re-resolves ``palette`` and re-skins observers.
    public var variant: AureanPaletteVariant

    /// The concrete palette resolved from the current ``variant``.
    ///
    /// Reading this from a SwiftUI body (directly or via ``SwiftUI/View/aureanTheme(_:)``)
    /// registers an observation dependency on ``variant``, so a later variant change
    /// re-invalidates the reader.
    public var palette: AureanPalette { variant.palette }

    /// Creates a theme owner.
    ///
    /// - Parameter variant: The initial temperature; defaults to
    ///   ``AureanPaletteVariant/cool`` (the cmux delivery default).
    public init(variant: AureanPaletteVariant = .cool) {
        self.variant = variant
    }
}
