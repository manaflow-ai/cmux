import Foundation

extension OnboardingModel.Step {
    /// This step's screen.
    var screen: any OnboardingScreenVariant.Type {
        switch self {
        case .agents: StandardAgents.self
        case .computerUseWelcome: StandardComputerUseWelcome.self
        case .importData: StandardImport.self
        case .computerUse: StandardComputerUse.self
        }
    }
}
