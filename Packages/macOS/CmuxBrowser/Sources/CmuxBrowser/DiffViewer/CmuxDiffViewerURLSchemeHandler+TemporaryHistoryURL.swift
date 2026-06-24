// CmuxDiffViewerURLSchemeHandler+TemporaryHistoryURL.swift
//
// Classifies whether a URL points at a transient diff-viewer surface that must
// never be persisted into browsing history. Co-located with the diff-viewer
// scheme handler because the rule is defined entirely by the diff-viewer
// concept: a URL is temporary when it uses the custom `cmux-diff-viewer` scheme,
// or when it is a loopback HTTP URL carrying the `cmux-diff-viewer` fragment
// (the local-server diff viewer presentation served over the loopback alias).

public import Foundation
import CmuxCore

extension CmuxDiffViewerURLSchemeHandler {
    /// Whether `url` addresses a transient diff-viewer surface that must be
    /// excluded from persisted browsing history.
    ///
    /// Returns `true` for the custom `cmux-diff-viewer` scheme, and for loopback
    /// HTTP URLs (localhost family or the loopback proxy alias host) that carry
    /// the `cmux-diff-viewer` fragment. Returns `false` for `nil`.
    public static func isTemporaryHistoryURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == Self.scheme {
            return true
        }
        guard url.fragment == "cmux-diff-viewer",
              url.scheme?.lowercased() == "http",
              let host = url.host else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(host) ||
            RemoteLoopbackProxyAlias.localhostFamilyHost(
                forAliasHost: host,
                aliasHost: RemoteLoopbackProxyAlias.aliasHost
            ) != nil
    }
}
