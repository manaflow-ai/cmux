/// The visual treatment a ``FeedButton`` renders in, used only by the
/// `#if DEBUG` style-exploration path.
///
/// In production a ``FeedButton`` always renders the `solid` treatment; this
/// enum exists so the app-side Feed Button Style debug window can swap the
/// button's fill, border, and shadow at runtime. The enum is a pure raw-value
/// value type so it can be persisted by an app-side `@AppStorage`/`UserDefaults`
/// repository and handed back into the package through ``FeedButtonDebugStyle``.
///
/// App-side concerns (a localized `label`, `CaseIterable`, `Identifiable` for
/// the picker UI) live in an extension in the app target, keeping localization
/// out of the package.
public enum FeedButtonVisualStyle: String, Sendable {
    /// Production treatment: an opaque fill with no border or shadow.
    case solid
    /// Raycast-flavored thin-material glass.
    case glass
    /// `regularMaterial` glass approximating the system `.glass` button style.
    case standardGlass
    /// `standardGlass` tinted by the button's kind color.
    case standardTintedGlass
    /// macOS 26 `glassEffect`-backed clear glass.
    case nativeGlass
    /// macOS 26 prominent `glassEffect` with a stronger tint.
    case nativeProminentGlass
    /// Ultra-thin material with a diagonal screen-blended highlight.
    case liquid
    /// Thin material with a radial top-leading highlight and colored glow.
    case halo
    /// Dark command-palette treatment.
    case command
    /// Light command-palette treatment.
    case commandLight
    /// Outline-only treatment that fills on hover/selection.
    case outline
    /// Borderless treatment that fills faintly on hover/selection.
    case flat
}
