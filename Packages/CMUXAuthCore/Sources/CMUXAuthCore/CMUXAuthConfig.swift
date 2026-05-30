import Foundation

public enum CMUXAuthEnvironment: Sendable {
    case development
    case production
}

public struct CMUXAuthConfig: Equatable, Sendable {
    public let projectId: String
    public let publishableClientKey: String

    public init(projectId: String, publishableClientKey: String) {
        self.projectId = projectId
        self.publishableClientKey = publishableClientKey
    }

    public static func resolve(
        environment: CMUXAuthEnvironment,
        overrides: [String: String] = [:],
        developmentProjectId: String,
        productionProjectId: String,
        developmentPublishableClientKey: String,
        productionPublishableClientKey: String
    ) -> Self {
        let projectId: String
        let publishableClientKey: String

        switch environment {
        case .development:
            projectId = overrides["STACK_PROJECT_ID_DEV"] ?? developmentProjectId
            publishableClientKey = overrides["STACK_PUBLISHABLE_CLIENT_KEY_DEV"] ?? developmentPublishableClientKey
        case .production:
            projectId = overrides["STACK_PROJECT_ID_PROD"] ?? productionProjectId
            publishableClientKey = overrides["STACK_PUBLISHABLE_CLIENT_KEY_PROD"] ?? productionPublishableClientKey
        }

        return Self(projectId: projectId, publishableClientKey: publishableClientKey)
    }
}
