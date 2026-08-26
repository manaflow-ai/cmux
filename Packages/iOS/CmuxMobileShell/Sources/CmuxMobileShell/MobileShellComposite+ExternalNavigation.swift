public import CMUXMobileCore
public import Foundation

/// Outcome of handing one external URL to the mobile workspace shell.
public enum MobileExternalNavigationURLResult: Equatable, Sendable {
    /// The URL is not a recognized workspace navigation route.
    case notNavigation
    /// The route was applied to the current workspace snapshot.
    case handled
    /// The route is recognized but its target is not loaded yet.
    case deferred
    /// The URL uses a recognized scheme and route but fails validation.
    case invalid(CmxNavigationURLParseError)
}

extension MobileShellComposite {
    /// Parses and applies a workspace, pane, or surface URL.
    ///
    /// The caller supplies the exact schemes registered by its app target. A
    /// deferred result is safe to retry after ``workspaceTopologyVersion``
    /// changes; no pairing connection is attempted for recognized routes.
    @discardableResult
    public func handleExternalNavigationURL(
        _ url: URL,
        supportedSchemes: Set<String>
    ) -> MobileExternalNavigationURLResult {
        switch CmxNavigationURLRequest.parse(url, supportedSchemes: supportedSchemes) {
        case .success(nil):
            return .notNavigation
        case .failure(let error):
            return .invalid(error)
        case .success(.some(let request)):
            switch MobileExternalNavigationTargetResolver(workspaces: workspaces).resolve(request) {
            case .unavailable:
                return .deferred
            case .resolved(let resolution):
                navigateToWorkspaceForDeeplink(resolution.workspaceID)
                switch resolution.selection {
                case .none:
                    break
                case .some(.terminal(let terminalID)):
                    selectTerminal(terminalID)
                case .some(.surface(let surfaceID)):
                    selectMacSurface(surfaceID)
                }
                return .handled
            }
        }
    }
}
