import Foundation
import CmuxBrowser

extension TerminalController {
    func v2BrowserImportDialog(params: [String: Any]) -> V2CallResult {
        let scope: BrowserImportScope?
        if params.keys.contains("scope") {
            guard let raw = v2String(params, "scope")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty else {
                return .err(code: "invalid_params", message: "scope must be a non-empty string", data: ["param": "scope"])
            }
            switch raw {
            case "cookie", "cookies", "cookiesonly", "cookies_only", "cookies-only":
                scope = .cookiesOnly
            case "history", "historyonly", "history_only", "history-only":
                scope = .historyOnly
            case "cookiesandhistory", "cookies_and_history", "cookies-and-history", "all-basic":
                scope = .cookiesAndHistory
            case "everything", "all":
                scope = .everything
            default:
                return .err(code: "invalid_params", message: "scope is invalid", data: ["param": "scope"])
            }
        } else {
            scope = nil
        }

        let defaultDestinationProfileID: UUID?
        if params.keys.contains("destination_profile") {
            guard let query = v2String(params, "destination_profile")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: "destination_profile must be a non-empty string",
                    data: ["param": "destination_profile"]
                )
            }
            let profiles = BrowserProfileStore.shared.profiles
            if let uuid = UUID(uuidString: query),
               profiles.contains(where: { $0.id == uuid }) {
                defaultDestinationProfileID = uuid
            } else if let profile = profiles.first(where: {
                $0.displayName.localizedCaseInsensitiveCompare(query) == .orderedSame ||
                    $0.slug.localizedCaseInsensitiveCompare(query) == .orderedSame
            }) {
                defaultDestinationProfileID = profile.id
            } else if v2Bool(params, "create_destination_profile") == true ||
                v2Bool(params, "create_profile") == true {
                guard let createdProfileID = BrowserProfileStore.shared.createProfile(named: query)?.id else {
                    return .err(
                        code: "invalid_params",
                        message: "destination_profile could not be created",
                        data: ["param": "destination_profile"]
                    )
                }
                defaultDestinationProfileID = createdProfileID
            } else {
                return .err(
                    code: "invalid_params",
                    message: "destination_profile does not match a cmux browser profile",
                    data: ["param": "destination_profile"]
                )
            }
        } else {
            defaultDestinationProfileID = nil
        }
        Task { @MainActor in
            self.browserDataImportCoordinator?.presentImportDialog(
                defaultDestinationProfileID: defaultDestinationProfileID,
                defaultScope: scope
            )
        }
        return .ok([
            "opened": true,
            "scope": scope.map { $0.rawValue as Any } ?? NSNull(),
        ])
    }

}
