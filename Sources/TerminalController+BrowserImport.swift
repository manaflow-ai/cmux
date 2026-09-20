import Foundation
import CmuxBrowser

extension TerminalController {
    func v2BrowserImportDialog(params: [String: Any]) -> V2CallResult {
        guard let coordinator = browserDataImportCoordinator else {
            return .err(
                code: "not_ready",
                message: String(localized: "browser.import.error.title", defaultValue: "Import could not start"),
                data: nil
            )
        }
        guard coordinator.isPresentationAvailable else {
            return .err(
                code: "busy",
                message: String(localized: "browser.import.error.title", defaultValue: "Import could not start"),
                data: nil
            )
        }
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
        do {
            defaultDestinationProfileID = try BrowserImportDestinationResolver.resolve(
                params: params,
                destinationProfiles: BrowserProfileStore.shared.profiles
            )
        } catch {
            return .err(code: "invalid_params", message: error.localizedDescription, data: nil)
        }
        guard coordinator.presentImportDialog(
                defaultDestinationProfileID: defaultDestinationProfileID,
                defaultScope: scope
            ) else {
            return .err(code: "busy", message: String(localized: "browser.import.error.title", defaultValue: "Import could not start"), data: nil)
        }
        return .ok([
            "opened": true,
            "scope": scope.map { $0.rawValue as Any } ?? NSNull(),
        ])
    }

}
