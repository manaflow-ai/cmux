/// What a window is (plans/cmux-next/windows.md). The kind alone decides a
/// window's chrome, background, close semantics and what each shortcut
/// means there. Overlay panels (palette, hover cards,
/// sheets) are not kinds: they resolve to their root window's
/// kind (``WindowKindRegistry``).
///
/// The raw values are the `kind` of `debug.window_snapshot`.
public nonisolated enum WindowKind: String, CaseIterable, Sendable {
    case main
    case settings
    case debugSettings
    case appStore
    case onboarding
    case onboardingGallery
    case browserPopup
    case devTools
    case pageInfo
    case terminalDebug
    case browserDebug

    /// What every window of this kind has and does.
    public var traits: WindowKindTraits {
        switch self {
        case .main:
            WindowKindTraits(isMain: true, close: .contentFirst, surface: .content, hidesMinimizeAndZoom: false)
        case .onboarding, .browserPopup:
            WindowKindTraits(isMain: false, close: .window, surface: .backdrop, hidesMinimizeAndZoom: true)
        case .settings, .debugSettings, .appStore, .onboardingGallery, .devTools, .pageInfo, .terminalDebug, .browserDebug:
            WindowKindTraits(isMain: false, close: .window, surface: .backdrop, hidesMinimizeAndZoom: false)
        }
    }
}
