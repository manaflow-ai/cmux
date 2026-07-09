public import Foundation
import CmuxCore

public extension URL {
    /// `true` when this URL identifies an ephemeral, non-persistable browser
    /// destination that must never be recorded in browsing history: the cmux
    /// diff-viewer custom scheme, or an `http` loopback URL carrying the
    /// `cmux-diff-viewer` fragment (the loopback-proxy alias form). Mirrors the
    /// legacy free function `browserIsTemporaryHistoryURL(_:)`; call sites that
    /// hold an optional URL spell the nil-is-not-temporary case as
    /// `url?.isTemporaryBrowserHistory ?? false`.
    var isTemporaryBrowserHistory: Bool {
        if scheme?.lowercased() == CmuxDiffViewerURLSchemeHandler.scheme {
            return true
        }
        guard fragment == "cmux-diff-viewer",
              scheme?.lowercased() == "http",
              let host else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(host) ||
            RemoteLoopbackProxyAlias.localhostFamilyHost(
                forAliasHost: host,
                aliasHost: RemoteLoopbackProxyAlias.aliasHost
            ) != nil
    }
}
