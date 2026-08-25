public import CmuxMobileShellModel
public import Foundation

/// Downloads the over-the-air task-model catalog used when a selected Mac
/// cannot enumerate models from its installed agent.
public struct MobileTaskModelCatalogClient: Sendable {
    /// Injectable transport used by package tests and debug previews.
    public typealias Loader = @Sendable (URL) async throws -> Data

    private let endpoint: URL
    private let loader: Loader

    /// Creates a model-catalog client.
    ///
    /// - Parameters:
    ///   - endpoint: Catalog endpoint passed to `loader` on every refresh.
    ///   - loader: Asynchronous catalog transport.
    public init(
        endpoint: URL,
        loader: @escaping Loader
    ) {
        self.endpoint = endpoint
        self.loader = loader
    }

    /// Production client. Every refresh performs a request so a currently
    /// installed app can observe newly released models without an app update.
    public static func live() -> Self {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = environment["CMUX_AGENT_MODELS_URL"]
            .flatMap(URL.init(string:))
            ?? productionEndpoint
        return Self(endpoint: endpoint) { endpoint in
            var request = URLRequest(
                url: endpoint,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 10
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw MobileTaskModelCatalogError.unsuccessfulResponse
            }
            return data
        }
    }

    /// Fetches and parses one provider's latest backend models.
    public func models(
        for provider: MobileTaskAgentProvider
    ) async throws -> [MobileTaskAgentModel] {
        let data = try await loader(endpoint)
        return try Self.result(from: data, provider: provider).models
    }

    /// Fetches one provider's latest backend models and its implicit Default
    /// selection metadata.
    public func result(
        for provider: MobileTaskAgentProvider
    ) async throws -> MobileTaskModelListResult {
        let data = try await loader(endpoint)
        return try Self.result(from: data, provider: provider)
    }

    /// Parses one provider from the versioned backend payload.
    public static func models(
        from data: Data,
        provider: MobileTaskAgentProvider
    ) throws -> [MobileTaskAgentModel] {
        try result(from: data, provider: provider).models
    }

    /// Parses one provider's models and resolves its Default selection to the
    /// matching catalog model without adding that model to the Default row.
    public static func result(
        from data: Data,
        provider: MobileTaskAgentProvider
    ) throws -> MobileTaskModelListResult {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schemaVersion == 1,
              let providerCatalog = catalog.providers[provider.rawValue] else {
            throw MobileTaskModelCatalogError.invalidCatalog
        }

        var seenIDs: Set<String> = []
        var models: [MobileTaskAgentModel] = []
        models.reserveCapacity(providerCatalog.models.count)
        for model in providerCatalog.models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = model.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !label.isEmpty, seenIDs.insert(id).inserted else {
                continue
            }
            var seenEffortIDs: Set<String> = []
            let efforts = (model.efforts ?? []).compactMap { effort -> MobileTaskAgentEffort? in
                let effortID = effort.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let effortLabel = effort.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !effortID.isEmpty, !effortLabel.isEmpty,
                      seenEffortIDs.insert(effortID).inserted else { return nil }
                let description = effort.description?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return MobileTaskAgentEffort(
                    id: effortID,
                    displayName: effortLabel,
                    description: description.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
            models.append(MobileTaskAgentModel(
                id: id,
                displayName: label,
                efforts: efforts,
                defaultEffortID: model.defaultEffort?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        guard !models.isEmpty else {
            throw MobileTaskModelCatalogError.invalidCatalog
        }
        let defaultModelID = providerCatalog.defaultModel?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let defaultModel = models.first {
            $0.id == defaultModelID
        }
        return MobileTaskModelListResult(
            models: models,
            source: .backend,
            defaultModel: defaultModel
        )
    }

    private static let productionEndpoint = URL(
        string: "https://cmux.com/api/agent-models"
    )!

    private struct Catalog: Decodable {
        let schemaVersion: Int
        let providers: [String: ProviderCatalog]
    }

    private struct ProviderCatalog: Decodable {
        let defaultModel: String?
        let models: [Model]
    }

    private struct Model: Decodable {
        let id: String
        let label: String
        let efforts: [Effort]?
        let defaultEffort: String?
    }

    private struct Effort: Decodable {
        let value: String
        let label: String
        let description: String?
    }
}

private enum MobileTaskModelCatalogError: Error {
    case unsuccessfulResponse
    case invalidCatalog
}
