/// The Theme screen's variants, in gallery order (the first is the default).
/// Add a variant: one file with one `OnboardingScreenVariant` type, then
/// list it here.
@MainActor
enum ThemeVariants {
    static let all: [any OnboardingScreenVariant.Type] = [
        StandardTheme.self,
        ThemeHeroPreview.self,
        ThemeFilmstrip.self,
        ThemeTintedRows.self,
        ThemeGrid.self,
        ThemeEditorial.self,
        ThemeImmersive.self,
        ThemeDarkLight.self,
        ThemeMinimalList.self,
        ThemeSwatches.self,
        ThemeStepper.self,
        ThemeSidebar.self,
    ]
}
