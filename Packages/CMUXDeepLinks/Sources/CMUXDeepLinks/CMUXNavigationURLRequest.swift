public import Foundation

public enum CMUXNavigationURLParseError: Error, Equatable, Sendable {
    case unsupportedURLShape
    case invalidIdentifier(String)
}

public struct CMUXNavigationURLRequest: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case workspace(UUID)
        case pane(workspaceId: UUID, paneId: UUID)
        case surface(workspaceId: UUID, surfaceId: UUID)
    }

    public let originalURL: URL
    public let target: Target

    public init(originalURL: URL, target: Target) {
        self.originalURL = originalURL
        self.target = target
    }

    public static func parse(
        _ url: URL,
        supportedSchemes: Set<String>
    ) -> Result<CMUXNavigationURLRequest?, CMUXNavigationURLParseError> {
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
            return .success(CMUXNavigationURLRequest(originalURL: url, target: .workspace(workspaceId)))
        }

        let childKind = route[2].lowercased()
        guard let childId = UUID(uuidString: route[3]) else {
            switch childKind {
            case "pane":
                return .failure(.invalidIdentifier("pane"))
            case "surface", "panel", "tab":
                return .failure(.invalidIdentifier(childKind == "tab" ? "tab" : "surface"))
            default:
                return .failure(.unsupportedURLShape)
            }
        }

        switch childKind {
        case "pane":
            return .success(
                CMUXNavigationURLRequest(
                    originalURL: url,
                    target: .pane(workspaceId: workspaceId, paneId: childId)
                )
            )
        case "surface", "panel", "tab":
            return .success(
                CMUXNavigationURLRequest(
                    originalURL: url,
                    target: .surface(workspaceId: workspaceId, surfaceId: childId)
                )
            )
        default:
            return .failure(.unsupportedURLShape)
        }
    }

    public static func workspaceLink(workspaceId: UUID, scheme: String) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)"
    }

    public static func paneLink(
        workspaceId: UUID,
        paneId: UUID,
        scheme: String
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/pane/\(paneId.uuidString)"
    }

    public static func surfaceLink(
        workspaceId: UUID,
        surfaceId: UUID,
        scheme: String
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)"
    }

    public static func tabLink(
        workspaceId: UUID,
        tabId: UUID,
        scheme: String
    ) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/tab/\(tabId.uuidString)"
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
