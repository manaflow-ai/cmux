import CmuxAuthRuntime

enum OAuthSignInProvider: CaseIterable, Hashable {
    case apple
    case google
    case github

    var analyticsMethod: String {
        switch self {
        case .apple: return "apple"
        case .google: return "google"
        case .github: return "github"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .apple: return "signin.apple"
        case .google: return "signin.google"
        case .github: return "signin.github"
        }
    }

    func signIn(using coordinator: AuthCoordinator) async throws {
        switch self {
        case .apple:
            try await coordinator.signInWithApple()
        case .google:
            try await coordinator.signInWithGoogle()
        case .github:
            try await coordinator.signInWithGitHub()
        }
    }
}
