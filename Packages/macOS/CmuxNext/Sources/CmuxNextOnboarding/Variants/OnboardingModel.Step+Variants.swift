import Foundation

/// Every screen variant, per step, in gallery order (the first is the
/// default). Each screen's list lives in its own file.
extension OnboardingModel.Step {
    /// This step's screen variants in gallery order; the first is the default.
    public var variants: [any OnboardingScreenVariant.Type] {
        switch self {
        case .role: RoleVariants.all
        case .firstTask: FirstTaskVariants.all
        case .projects: ProjectsVariants.all
        case .classicSessions: ClassicSessionsVariants.all
        case .chats: ChatsVariants.all
        case .defaultBrowser: DefaultBrowserVariants.all
        case .importData: ImportVariants.all
        case .theme: ThemeVariants.all
        case .computerUse: ComputerUseVariants.all
        case .accounts: AccountsVariants.all
        }
    }

    /// Every step's variants, in step order then gallery order.
    public static var allVariants: [any OnboardingScreenVariant.Type] {
        allCases.flatMap(\.variants)
    }

    /// The variant with `id`, from any step.
    ///
    /// - Parameter id: A variant's ``OnboardingScreenVariant/id``.
    /// - Returns: Nil when no step has it.
    public static func variant(id: String) -> (any OnboardingScreenVariant.Type)? {
        allVariants.first { $0.id == id }
    }

    /// The variant the flow uses for this step: the stored pick, else the first.
    ///
    /// - Parameter id: The stored pick, if any.
    /// - Returns: The picked variant when it belongs to this step, else the default.
    public func chosenVariant(id: String?) -> any OnboardingScreenVariant.Type {
        let list = variants
        return list.first { $0.id == id } ?? list[0]
    }
}
