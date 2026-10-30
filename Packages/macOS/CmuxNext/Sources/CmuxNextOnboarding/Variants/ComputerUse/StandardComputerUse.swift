import AppKit

/// Computer Use setup: the helper's icon, a title, a row per grant with
/// the next missing one's Allow filled, on full-window glass.
struct StandardComputerUse: OnboardingScreenVariant {
    static let step = OnboardingModel.Step.computerUse
    static let surface = OnboardingSurface.fullGlass
    static var size: NSSize { ComputerUseSetupView.size }
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        ComputerUseSetupView(model: context.model.computerUse, context: context)
    }
}
