public import Foundation

/// A validated `cmux://workspace/...` deep link that focuses an existing
/// workspace, pane, or surface.
///
/// Parsing is pure and byte-faithful to the legacy implementation. The active
/// deep-link scheme set and the default link scheme are NOT resolved here;
/// callers pass them explicitly (the app shell adds scheme-defaulted
/// conveniences in its own extension) so the package stays free of the app's
/// `AuthEnvironment`.
public struct CmuxNavigationURLRequest: Equatable {
    /// The navigation destination encoded by the link.
    public enum Target: Equatable {
        case workspace(UUID)
        case pane(workspaceId: UUID, paneId: UUID)
        case surface(workspaceId: UUID, surfaceId: UUID)
    }

    public let originalURL: URL
    public let target: Target

    /// Parses `url` against the supplied active scheme set.
    public static func parse(
        _ url: URL,
        supportedSchemes: Set<String>
    ) -> Result<CmuxNavigationURLRequest?, CmuxNavigationURLParseError> {
        guard isSupportedScheme(url.scheme, supportedSchemes: supportedSchemes) else {
            return .success(nil)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unsupportedURLShape)
        }

        let route = routeComponents(from: components)
        guard route.first?.lowercased() == "workspace" else {
            return .success(nil)
        }

        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else {
            return .failure(.unsupportedURLShape)
        }

        guard route.count == 2 || route.count == 4 else {
            return .failure(.unsupportedURLShape)
        }
        guard let workspaceId = UUID(uuidString: route[1]) else {
            return .failure(.invalidIdentifier("workspace"))
        }
        if route.count == 2 {
            return .success(CmuxNavigationURLRequest(originalURL: url, target: .workspace(workspaceId)))
        }

        let childKind = route[2].lowercased()
        guard let childId = UUID(uuidString: route[3]) else {
            switch childKind {
            case "pane":
                return .failure(.invalidIdentifier("pane"))
            case "surface", "panel":
                return .failure(.invalidIdentifier("surface"))
            default:
                return .failure(.unsupportedURLShape)
            }
        }

        switch childKind {
        case "pane":
            return .success(
                CmuxNavigationURLRequest(
                    originalURL: url,
                    target: .pane(workspaceId: workspaceId, paneId: childId)
                )
            )
        case "surface", "panel":
            return .success(
                CmuxNavigationURLRequest(
                    originalURL: url,
                    target: .surface(workspaceId: workspaceId, surfaceId: childId)
                )
            )
        default:
            return .failure(.unsupportedURLShape)
        }
    }

    /// The `scheme://workspace/<id>` link for a workspace.
    public static func workspaceLink(workspaceId: UUID, scheme: String) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)"
    }

    /// The `scheme://workspace/<id>/pane/<id>` link for a pane.
    public static func paneLink(
        workspaceId: UUID,
        paneId: UUID,
        scheme: String
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/pane/\(paneId.uuidString)"
    }

    /// The `scheme://workspace/<id>/surface/<id>` link for a surface.
    public static func surfaceLink(
        workspaceId: UUID,
        surfaceId: UUID,
        scheme: String
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)"
    }

    private static func isSupportedScheme(_ scheme: String?, supportedSchemes: Set<String>) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return supportedSchemes.contains(scheme)
    }

    private static func routeComponents(from components: URLComponents) -> [String] {
        var route: [String] = []
        if let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            route.append(host)
        }
        route += components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return route
    }
}
