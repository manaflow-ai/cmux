import AppKit

/// Import from Browser: leading title, a checkbox per browser profile, one
/// line of kinds, full-window glass.
struct StandardImport: OnboardingScreenVariant {
    static let step = OnboardingModel.Step.importData
    static let surface = OnboardingSurface.fullGlass
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.importTitle, subtitle: nil,
                                body: ImportStepView(model: context.model.importer), context: context)
    }
}
