import AppKit

/// The landed minimal design (2026-10-01): leading title, one sentence, the
/// system control, full-window glass, crossfade. First in each screen's list.
struct StandardDefaultBrowser: OnboardingScreenVariant {
    static let id = "defaultBrowser.standard"
    static let step = OnboardingModel.Step.defaultBrowser
    static let name = "Standard"
    static let summary = "Leading title, current browser, one button."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.browserTitle, subtitle: OnboardingStrings.browserSubtitle,
                                body: DefaultBrowserStepView(model: context.model.defaults), context: context)
    }
}

struct StandardImport: OnboardingScreenVariant {
    static let id = "importData.standard"
    static let step = OnboardingModel.Step.importData
    static let name = "Standard"
    static let summary = "Checkbox per profile, one line of kinds."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        return OnboardingScaffold.make(title: OnboardingStrings.importTitle, subtitle: OnboardingStrings.importSubtitle,
                                body: ImportStepView(model: context.model.importer), context: context)
    }
}

struct StandardTheme: OnboardingScreenVariant {
    static let id = "theme.standard"
    static let step = OnboardingModel.Step.theme
    static let name = "Standard"
    static let summary = "Radio list beside a terminal preview."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.themeTitle, subtitle: OnboardingStrings.themeSubtitle,
                                body: ThemeStepView(model: context.model.theme), context: context)
    }
}
