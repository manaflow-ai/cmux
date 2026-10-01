import Foundation

/// Every screen variant, per step, in gallery order (the first is the
/// default). Each screen's list lives in its own file.
@MainActor
public enum OnboardingVariantRegistry {
    public static func variants(for step: OnboardingModel.Step) -> [any OnboardingScreenVariant.Type] {
        switch step {
        case .defaultBrowser: DefaultBrowserVariants.all
        case .importData: ImportVariants.all
        case .theme: ThemeVariants.all
        case .accounts: AccountsVariants.all
        }
    }

    public static var all: [any OnboardingScreenVariant.Type] {
        OnboardingModel.Step.allCases.flatMap(variants(for:))
    }

    public static func variant(id: String) -> (any OnboardingScreenVariant.Type)? {
        all.first { $0.id == id }
    }

    /// The variant the flow uses for `step`: the stored pick, else the first.
    public static func chosen(for step: OnboardingModel.Step, id: String?) -> any OnboardingScreenVariant.Type {
        let list = variants(for: step)
        return list.first { $0.id == id } ?? list[0]
    }
}
