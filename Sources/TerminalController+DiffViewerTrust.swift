import CmuxBrowser
import Foundation

/// Off-main validation result passed through the socket worker's existing main hop.
nonisolated enum DiffViewerSessionRegistrationPreparation: Sendable {
    case notNeeded
    case prepared(CmuxDiffViewerPreparedSession)
    case invalid(message: String, details: String?)
}

extension TerminalController {
    func v2IsDiffViewerURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == CmuxDiffViewerURLSchemeHandler.scheme {
            return true
        }
        return url.scheme?.lowercased() == "http" &&
            url.host == "127.0.0.1" &&
            url.fragment == "cmux-diff-viewer"
    }

    /// Parses, validates, canonicalizes, and leases a custom-scheme allowlist on
    /// the socket worker before any browser UI mutation reaches the main actor.
    nonisolated func v2PrepareDiffViewerRegistration(
        params: [String: Any]
    ) -> DiffViewerSessionRegistrationPreparation {
        guard let rawURL = params["url"] as? String,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == CmuxDiffViewerURLSchemeHandler.scheme else {
            return .notNeeded
        }
        guard let token = params["diff_viewer_token"] as? String,
              token == url.host,
              let rawFiles = params["diff_viewer_files"] as? [[String: Any]],
              !rawFiles.isEmpty,
              rawFiles.count <= CmuxDiffViewerURLSchemeHandler.maxRegisteredFiles else {
            return .invalid(
                message: "Missing or invalid trusted diff viewer allowlist",
                details: nil
            )
        }
        guard !Thread.isMainThread else {
            return .invalid(
                message: "Invalid trusted diff viewer allowlist",
                details: nil
            )
        }

        let files = rawFiles.compactMap(CmuxDiffViewerURLSchemeHandler.registeredFile(from:))
        guard files.count == rawFiles.count else {
            return .invalid(
                message: "Invalid trusted diff viewer allowlist",
                details: nil
            )
        }
        do {
            let prepared = try CmuxDiffViewerSessionPreparer().prepare(
                token: token,
                files: files
            )
            return .prepared(prepared)
        } catch {
            return .invalid(
                message: "Invalid trusted diff viewer allowlist",
                details: error.localizedDescription
            )
        }
    }

    func v2RegisterDiffViewerURLIfNeeded(
        params: [String: Any],
        url: URL?,
        preparation: DiffViewerSessionRegistrationPreparation
    ) -> V2CallResult? {
        guard let url, v2IsDiffViewerURL(url) else { return nil }
        guard let token = params["diff_viewer_token"] as? String else {
            return .err(code: "invalid_params", message: "Missing trusted diff viewer session", data: nil)
        }
        if url.scheme != CmuxDiffViewerURLSchemeHandler.scheme {
            guard DiffViewerSessionTrustRegistry.shared.registerLiveHTTPURL(url, token: token) else {
                return .err(code: "invalid_params", message: "Invalid trusted diff viewer session", data: nil)
            }
            return nil
        }
        guard token == url.host else {
            return .err(code: "invalid_params", message: "Missing or invalid trusted diff viewer allowlist", data: nil)
        }

        switch preparation {
        case .prepared(let prepared) where prepared.token == token:
            CmuxDiffViewerURLSchemeHandler.shared.install(prepared)
            return nil
        case .invalid(let message, let details):
            return .err(
                code: "invalid_params",
                message: message,
                data: details.map { ["details": $0] as [String: Any] }
            )
        case .notNeeded, .prepared:
            return .err(
                code: "invalid_params",
                message: "Missing or invalid trusted diff viewer allowlist",
                data: nil
            )
        }
    }
}
