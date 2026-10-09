import AppKit

/// Two radios: Ctrl-1…9 select tabs (the default) or Spaces.
struct StandardTabKeys: OnboardingScreenVariant {
    static let id = "tabKeys.standard"
    static let step = OnboardingModel.Step.tabKeys
    static let name = "Standard"
    static let summary = "Two radio rows: tabs or Spaces on Ctrl-1…9."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        NSView()
    }
}
