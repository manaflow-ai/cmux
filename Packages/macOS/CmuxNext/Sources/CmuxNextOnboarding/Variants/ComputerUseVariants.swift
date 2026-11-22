/// The Computer Use screen's variants, in gallery order (the first is the
/// default). Add a variant: one file with one `OnboardingScreenVariant`
/// type, then list it here.
@MainActor
enum ComputerUseVariants {
    static let all: [any OnboardingScreenVariant.Type] = [
        StandardComputerUse.self,
    ]
}
