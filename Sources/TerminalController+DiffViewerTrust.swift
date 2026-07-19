import Foundation

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

    func v2RegisterDiffViewerURLIfNeeded(params: [String: Any], url: URL?) -> V2CallResult? {
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
        guard token == url.host,
              let rawFiles = params["diff_viewer_files"] as? [[String: Any]],
              !rawFiles.isEmpty,
              rawFiles.count <= CmuxDiffViewerURLSchemeHandler.maxRegisteredFiles else {
            return .err(code: "invalid_params", message: "Missing or invalid trusted diff viewer allowlist", data: nil)
        }

        let files = rawFiles.compactMap(CmuxDiffViewerURLSchemeHandler.registeredFile(from:))
        guard files.count == rawFiles.count else {
            return .err(code: "invalid_params", message: "Invalid trusted diff viewer allowlist", data: nil)
        }

        do {
            try CmuxDiffViewerURLSchemeHandler.shared.register(token: token, files: files)
            return nil
        } catch {
            return .err(
                code: "invalid_params",
                message: "Invalid trusted diff viewer allowlist",
                data: ["details": error.localizedDescription]
            )
        }
    }
}
