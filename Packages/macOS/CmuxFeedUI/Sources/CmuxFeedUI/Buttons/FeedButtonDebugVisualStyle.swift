#if DEBUG
/// DEBUG-only enumeration of the visual treatments the Feed button
/// style playground can apply to ``FeedButton``. The localized
/// ``label`` lives app-side (it resolves `String(localized:)` against
/// the app bundle); this package owns only the cases and identity.
public enum FeedButtonDebugVisualStyle: String, CaseIterable, Identifiable {
    case solid
    case glass
    case standardGlass
    case standardTintedGlass
    case nativeGlass
    case nativeProminentGlass
    case liquid
    case halo
    case command
    case commandLight
    case outline
    case flat

    public var id: String { rawValue }
}
#endif
