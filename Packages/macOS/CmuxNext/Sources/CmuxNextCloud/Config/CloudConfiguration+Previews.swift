public import Foundation

extension CloudConfiguration {
    /// Preview ingress comes from the selected backend's client-config.
    public func platformPreviewAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        runtimeSelection?.platformOrigin
    }

    /// Artifact requests use the selected backend's platform origin.
    public func artifactsAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        runtimeSelection?.platformOrigin
    }
}
