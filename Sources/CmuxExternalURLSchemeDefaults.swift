import CmuxRemoteWorkspace
import Foundation

// The deep-link parse types live in `CmuxRemoteWorkspace`, which is below the
// auth domain in the dependency graph and therefore cannot read
// `AuthEnvironment`. The active deep-link scheme is build-specific (stable,
// nightly, or a per-tag dev scheme), so the app shell — the single owner of
// `AuthEnvironment` — re-adds the scheme-defaulted conveniences here as
// extensions on the package types. Every legacy call site (`parse(url)`, the
// link builders without an explicit `scheme:`) keeps byte-identical behavior:
// the no-scheme overloads resolve to these app extensions, while explicit
// `supportedSchemes:` / `scheme:` calls bind directly to the package methods.

extension CmuxSSHURLRequest {
    /// The deep-link schemes this running build accepts.
    static var activeSupportedSchemes: Set<String> {
        [AuthEnvironment.callbackScheme.lowercased()]
    }

    /// Parses `url` against the running build's active scheme set.
    static func parse(_ url: URL) -> Result<CmuxSSHURLRequest?, CmuxSSHURLParseError> {
        parse(url, supportedSchemes: activeSupportedSchemes)
    }
}

extension CmuxNavigationURLRequest {
    /// The deep-link schemes this running build accepts.
    static var activeSupportedSchemes: Set<String> {
        [AuthEnvironment.callbackScheme.lowercased()]
    }

    /// Parses `url` against the running build's active scheme set.
    static func parse(_ url: URL) -> Result<CmuxNavigationURLRequest?, CmuxNavigationURLParseError> {
        parse(url, supportedSchemes: activeSupportedSchemes)
    }

    /// The workspace link for this running build's callback scheme.
    static func workspaceLink(workspaceId: UUID) -> String {
        workspaceLink(workspaceId: workspaceId, scheme: AuthEnvironment.callbackScheme)
    }

    /// The pane link for this running build's callback scheme.
    static func paneLink(workspaceId: UUID, paneId: UUID) -> String {
        paneLink(workspaceId: workspaceId, paneId: paneId, scheme: AuthEnvironment.callbackScheme)
    }

    /// The surface link for this running build's callback scheme.
    static func surfaceLink(workspaceId: UUID, surfaceId: UUID) -> String {
        surfaceLink(workspaceId: workspaceId, surfaceId: surfaceId, scheme: AuthEnvironment.callbackScheme)
    }
}

extension CmuxTextURLRequest {
    /// The deep-link schemes this running build accepts.
    static var activeSupportedSchemes: Set<String> {
        CmuxSSHURLRequest.activeSupportedSchemes
    }

    /// Parses `url` against the running build's active scheme set.
    static func parse(_ url: URL) -> Result<CmuxTextURLRequest?, CmuxTextURLParseError> {
        parse(url, supportedSchemes: activeSupportedSchemes)
    }
}
