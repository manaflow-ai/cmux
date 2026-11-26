import Foundation
import CmuxBrowser

@MainActor
struct BrowserImportDestinationResolver {
    private let packageResolver = CmuxBrowser.BrowserImportDestinationResolver()

    func resolve(
        params: [String: Any],
        destinationProfiles: [BrowserProfileDefinition]
    ) throws -> UUID? {
        let selector = ["destination_profile", "to_profile", "to"].lazy.compactMap { key in
            (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
        let identifier = (params["destination_profile_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolution = packageResolver.resolve(
            rawSelector: selector,
            rawIdentifier: identifier,
            createIfMissing: BrowserAutomationParameters(values: params).bool(
                keys: ["create_destination_profile", "create_profile"]
            ),
            profiles: destinationProfiles
        )
        switch resolution {
        case .none:
            return nil
        case .matched(let id):
            return id
        case .ambiguous(let profiles):
            throw BrowserProfileAutomationError.ambiguousProfile(selector ?? identifier ?? "", profiles)
        case .notFound(let value), .invalidIdentifier(let value):
            throw BrowserImportAutomationError.destinationProfileNotFound(value)
        case .create(let name):
            guard let profile = BrowserProfileStore.shared.createProfile(named: name) else {
                throw BrowserImportAutomationError.destinationProfileCreationFailed(name)
            }
            return profile.id
        }
    }
}
