import Foundation

extension OnboardingModel.Step {
    /// The step's short name in the review tool (developer text, not localized).
    var galleryName: String {
        switch self {
        case .role: "Role"
        case .defaultBrowser: "Default Browser"
        case .importData: "Import"
        case .theme: "Theme"
        case .computerUse: "Computer Use"
        case .accounts: "Accounts"
        }
    }
}
