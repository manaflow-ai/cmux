import Foundation
import CmuxBrowser

@MainActor
enum BrowserImportDestinationResolver {
    static func resolve(
        params: [String: Any],
        destinationProfiles: [BrowserProfileDefinition]
    ) throws -> UUID? {
        if let rawID = stringParam(params, key: "destination_profile_id") {
            guard let id = UUID(uuidString: rawID),
                  destinationProfiles.contains(where: { $0.id == id }) else {
                throw BrowserImportAutomationError.destinationProfileNotFound(rawID)
            }
            return id
        }

        guard let query = stringParam(
            params,
            keys: ["destination_profile", "to_profile", "to"]
        ) else { return nil }
        if let id = UUID(uuidString: query) {
            guard destinationProfiles.contains(where: { $0.id == id }) else {
                throw BrowserImportAutomationError.destinationProfileNotFound(query)
            }
            return id
        }

        let matches = destinationProfiles.filter {
            $0.displayName.localizedCaseInsensitiveCompare(query) == .orderedSame
                || $0.slug.localizedCaseInsensitiveCompare(query) == .orderedSame
        }
        if matches.count == 1 { return matches[0].id }
        if matches.count > 1 {
            throw BrowserProfileAutomationError.ambiguousProfile(query, matches)
        }
        guard BrowserAutomationParameters(values: params).bool(
            keys: ["create_destination_profile", "create_profile"]
        ) else {
            throw BrowserImportAutomationError.destinationProfileNotFound(query)
        }
        guard let profile = BrowserProfileStore.shared.createProfile(named: query) else {
            throw BrowserImportAutomationError.destinationProfileCreationFailed(query)
        }
        return profile.id
    }

    private static func stringParam(_ params: [String: Any], key: String) -> String? {
        guard let value = params[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringParam(_ params: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { stringParam(params, key: $0) }.first
    }
}
