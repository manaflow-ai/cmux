import Foundation

extension AgentSurfaceResumePublicationRetry {
    enum BindingGeneration: Equatable {
        case missing
        /// A token minted by the app for the current surface owner generation.
        case owner(UUID)
        /// Compatibility fallback for apps that predate owner-generation payloads.
        case updatedAt(Double)
    }
}
