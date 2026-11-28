/// The DefaultBrowser screen's variants, in gallery order (the first is the default).
/// Add a variant: one file with one `OnboardingScreenVariant` type, then
/// list it here.
@MainActor
enum DefaultBrowserVariants {
    static let all: [any OnboardingScreenVariant.Type] = [
        StandardDefaultBrowser.self,
        CenteredHeroBrowser.self,
        StatusFirstBrowser.self,
        ChoiceRowsBrowser.self,
        SegmentedBrowser.self,
        FloatingCardBrowser.self,
        EditorialSplitBrowser.self,
        CheckboxRowBrowser.self,
        BottomBarBrowser.self,
        TopBarBrowser.self,
        FooterActionBrowser.self,
    ]
}
