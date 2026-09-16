import CmuxAuthRuntime

/// A sign-out fences its session until auth publishes a newly authenticated generation.
enum MobileHostAuthTransition {
    case ready
    case signingOut(generation: UInt64)

    func permits(_ identity: AuthenticatedSessionIdentity?) -> Bool {
        switch self {
        case .ready:
            return true
        case .signingOut(let generation):
            guard let identity else { return false }
            return identity.generation != generation
        }
    }
}
