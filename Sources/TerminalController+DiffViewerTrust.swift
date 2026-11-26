import CmuxBrowser
import Foundation

/// Off-main validation result passed through the socket worker's existing main hop.
enum DiffViewerSessionPreparation: Sendable {
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
    ) -> DiffViewerSessionPreparation {
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
                message: String(
                    localized: "cli.browser.error.diffViewerAllowlistMissingOrInvalid",
                    defaultValue: "Missing or invalid trusted diff viewer allowlist"
                ),
                details: nil
            )
        }
        guard !Thread.isMainThread else {
            return .invalid(
                message: String(
                    localized: "cli.browser.error.diffViewerAllowlistInvalid",
                    defaultValue: "Invalid trusted diff viewer allowlist"
                ),
                details: nil
            )
        }

        let files = rawFiles.compactMap(CmuxDiffViewerURLSchemeHandler.registeredFile(from:))
        guard files.count == rawFiles.count else {
            return .invalid(
                message: String(
                    localized: "cli.browser.error.diffViewerAllowlistInvalid",
                    defaultValue: "Invalid trusted diff viewer allowlist"
                ),
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
                message: String(
                    localized: "cli.browser.error.diffViewerAllowlistInvalid",
                    defaultValue: "Invalid trusted diff viewer allowlist"
                ),
                details: error.localizedDescription
            )
        }
    }

    /// Refreshes a custom-scheme session from its authoritative manifest on the socket worker.
    nonisolated func v2PrepareDiffViewerNavigation(
        params: [String: Any]
    ) -> DiffViewerSessionPreparation {
        guard let rawURL = params["url"] as? String,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == CmuxDiffViewerURLSchemeHandler.scheme else {
            return .notNeeded
        }
        guard let token = url.host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              !Thread.isMainThread else {
            return .invalid(
                message: String(
                    localized: "cli.browser.error.diffViewerSessionInvalid",
                    defaultValue: "Invalid trusted diff viewer session"
                ),
                details: nil
            )
        }

        do {
            return .prepared(
                try CmuxDiffViewerSessionPreparer().prepareFromManifest(token: token)
            )
        } catch {
            return .invalid(
                message: String(
                    localized: "cli.browser.error.diffViewerSessionInvalid",
                    defaultValue: "Invalid trusted diff viewer session"
                ),
                details: nil
            )
        }
    }

    func v2RegisterDiffViewerURLIfNeeded(
        params: [String: Any],
        url: URL?,
        preparation: DiffViewerSessionPreparation
    ) -> V2CallResult? {
        guard let url, v2IsDiffViewerURL(url) else { return nil }
        guard let token = params["diff_viewer_token"] as? String else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.error.diffViewerSessionMissing",
                    defaultValue: "Missing trusted diff viewer session"
                ),
                data: nil
            )
        }
        if url.scheme != CmuxDiffViewerURLSchemeHandler.scheme {
            guard DiffViewerSessionTrustRegistry.shared.registerLiveHTTPURL(url, token: token) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "cli.browser.error.diffViewerSessionInvalid",
                        defaultValue: "Invalid trusted diff viewer session"
                    ),
                    data: nil
                )
            }
            return nil
        }
        guard token == url.host else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.error.diffViewerAllowlistMissingOrInvalid",
                    defaultValue: "Missing or invalid trusted diff viewer allowlist"
                ),
                data: nil
            )
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
                message: String(
                    localized: "cli.browser.error.diffViewerAllowlistMissingOrInvalid",
                    defaultValue: "Missing or invalid trusted diff viewer allowlist"
                ),
                data: nil
            )
        }
    }

    /// Installs an off-main manifest refresh before the cache-only navigation trust gate.
    func v2InstallDiffViewerNavigationPreparationIfNeeded(
        rawURL: String,
        preparation: DiffViewerSessionPreparation
    ) -> V2CallResult? {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == CmuxDiffViewerURLSchemeHandler.scheme else {
            return nil
        }

        let handler = CmuxDiffViewerURLSchemeHandler.shared
        switch preparation {
        case .prepared(let prepared) where prepared.token == url.host:
            handler.install(prepared)
            return nil
        case .invalid(let message, _):
            guard !handler.allowsNavigation(to: url) else { return nil }
            return .err(code: "invalid_params", message: message, data: nil)
        case .notNeeded, .prepared:
            guard !handler.allowsNavigation(to: url) else { return nil }
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.browser.error.diffViewerSessionInvalid",
                    defaultValue: "Invalid trusted diff viewer session"
                ),
                data: nil
            )
        }
    }
}
