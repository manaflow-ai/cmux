/// The DefaultBrowser screen's variants, in gallery order (the first is the default).
/// Add a variant: one file with one `OnboardingScreenVariant` type, then
/// list it here.
@MainActor
enum DefaultBrowserVariants {
    static let all: [any OnboardingScreenVariant.Type] = [
        StandardDefaultBrowser.self,
    ]
}
