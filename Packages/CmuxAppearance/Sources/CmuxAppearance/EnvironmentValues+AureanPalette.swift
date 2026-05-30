import SwiftUI

/// Carries the resolved ``AureanPalette`` down the view tree, defaulting to cool.
private struct AureanPaletteKey: EnvironmentKey {
    static let defaultValue = AureanPalette(variant: .cool)
}

extension EnvironmentValues {
    /// The Aurean palette in effect for this view subtree.
    ///
    /// Defaults to `AureanPalette(variant: .cool)` when no ``AureanTheme`` has been
    /// injected, so a view reads sane colors even outside a themed root. Inject the active
    /// palette with ``SwiftUI/View/aureanTheme(_:)`` (which sources it from the observable
    /// ``AureanTheme``); read it with `@Environment(\.aureanPalette)`.
    ///
    /// ```swift
    /// @Environment(\.aureanPalette) private var palette
    /// var body: some View {
    ///     Text("ready")
    ///         .foregroundStyle(palette.ok.color)
    ///         .background(palette.surfacePrimary.color)
    /// }
    /// ```
    public var aureanPalette: AureanPalette {
        get { self[AureanPaletteKey.self] }
        set { self[AureanPaletteKey.self] = newValue }
    }
}
