public import Foundation

/// Errors produced while parsing a cmux workspace navigation URL.
public enum CmxNavigationURLParseError: Error, Equatable, Sendable {
    /// The URL has a recognized navigation route but an invalid shape.
    case unsupportedURLShape
    /// One of the UUID route components is malformed.
    case invalidIdentifier(String)
}

/// A parsed `workspace`, `pane`, or `surface` navigation URL.
///
/// The grammar is shared by macOS and iOS so links emitted by one app target
/// have one parser and one set of validation rules. Callers provide the URL
/// schemes registered by their app target; an unsupported scheme is ignored
/// rather than treated as a malformed navigation request.
public struct CmxNavigationURLRequest: Equatable, Sendable {
    /// The destination encoded by a navigation URL.
    public enum Target: Equatable, Sendable {
        /// Open a workspace.
        case workspace(UUID)
        /// Open the selected surface in a workspace pane.
        case pane(workspaceId: UUID, paneId: UUID)
        /// Open a specific surface in a workspace.
        case surface(workspaceId: UUID, surfaceId: UUID)
    }

    /// The URL delivered by the operating system.
    public let originalURL: URL
    /// The route destination.
    public let target: Target
    /// Optional restart-stable workspace identity carried by durable links.
    public let stableFallbackWorkspaceId: UUID?
    /// Optional restart-stable surface identity carried by durable links.
    public let stableFallbackSurfaceId: UUID?

    /// Creates a parsed navigation request.
    /// - Parameters:
    ///   - originalURL: The source URL.
    ///   - target: The route destination.
    ///   - stableFallbackWorkspaceId: Optional stable workspace fallback.
    ///   - stableFallbackSurfaceId: Optional stable surface fallback.
    public init(
        originalURL: URL,
        target: Target,
        stableFallbackWorkspaceId: UUID? = nil,
        stableFallbackSurfaceId: UUID? = nil
    ) {
        self.originalURL = originalURL
        self.target = target
        self.stableFallbackWorkspaceId = stableFallbackWorkspaceId
        self.stableFallbackSurfaceId = stableFallbackSurfaceId
    }

    /// Parses a URL when its scheme belongs to the caller's active app target.
    /// - Parameters:
    ///   - url: The URL to parse.
    ///   - supportedSchemes: Schemes registered by the caller. Comparison is
    ///     case-insensitive.
    /// - Returns: `success(nil)` for another cmux route or unsupported scheme,
    ///   a request for a recognized route, or a validation error.
    public static func parse(
        _ url: URL,
        supportedSchemes: Set<String>
    ) -> Result<CmxNavigationURLRequest?, CmxNavigationURLParseError> {
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
            switch parseStableFallback(from: components, allowedNames: ["stable_workspace_id"]) {
            case .success(let fallback):
                return .success(
                    CmxNavigationURLRequest(
                        originalURL: url,
                        target: .workspace(workspaceId),
                        stableFallbackWorkspaceId: fallback?.workspaceId,
                        stableFallbackSurfaceId: fallback?.surfaceId
                    )
                )
            case .failure(let error):
                return .failure(error)
            }
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
            // Pane links deliberately do not accept query items. Unlike a
            // surface link, a pane has no stable child fallback identity.
            guard components.percentEncodedQuery == nil else {
                return .failure(.unsupportedURLShape)
            }
            return .success(
                CmxNavigationURLRequest(
                    originalURL: url,
                    target: .pane(workspaceId: workspaceId, paneId: childId)
                )
            )
        case "surface", "panel":
            switch parseStableFallback(
                from: components,
                allowedNames: ["stable_workspace_id", "stable_surface_id"]
            ) {
            case .success(let fallback):
                return .success(
                    CmxNavigationURLRequest(
                        originalURL: url,
                        target: .surface(workspaceId: workspaceId, surfaceId: childId),
                        stableFallbackWorkspaceId: fallback?.workspaceId,
                        stableFallbackSurfaceId: fallback?.surfaceId
                    )
                )
            case .failure(let error):
                return .failure(error)
            }
        default:
            return .failure(.unsupportedURLShape)
        }
    }

    /// Builds a workspace navigation URL.
    public static func workspaceLink(workspaceId: UUID, scheme: String) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)"
    }

    /// Builds a pane navigation URL.
    public static func paneLink(workspaceId: UUID, paneId: UUID, scheme: String) -> String {
        "\(scheme)://workspace/\(workspaceId.uuidString)/pane/\(paneId.uuidString)"
    }

    /// Builds a surface navigation URL, optionally carrying stable fallbacks.
    public static func surfaceLink(
        workspaceId: UUID,
        surfaceId: UUID,
        stableWorkspaceId: UUID? = nil,
        stableSurfaceId: UUID? = nil,
        scheme: String
    ) -> String {
        var link = "\(scheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)"
        var queryItems: [String] = []
        if let stableWorkspaceId {
            queryItems.append("stable_workspace_id=\(stableWorkspaceId.uuidString)")
        }
        if let stableSurfaceId {
            queryItems.append("stable_surface_id=\(stableSurfaceId.uuidString)")
        }
        if !queryItems.isEmpty {
            link += "?\(queryItems.joined(separator: "&"))"
        }
        return link
    }

    private static func isSupportedScheme(
        _ scheme: String?,
        supportedSchemes: Set<String>
    ) -> Bool {
        guard let scheme else { return false }
        let normalized = scheme.lowercased()
        return supportedSchemes.contains { $0.lowercased() == normalized }
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

    private static func parseStableFallback(
        from components: URLComponents,
        allowedNames: Set<String>
    ) -> Result<(workspaceId: UUID?, surfaceId: UUID?)?, CmxNavigationURLParseError> {
        guard components.percentEncodedQuery != nil else { return .success(nil) }
        guard let items = components.queryItems, !items.isEmpty else {
            return .failure(.unsupportedURLShape)
        }

        var stableWorkspaceId: UUID?
        var stableSurfaceId: UUID?
        var seenNames: Set<String> = []
        for item in items {
            guard allowedNames.contains(item.name),
                  seenNames.insert(item.name).inserted,
                  let value = item.value,
                  !value.isEmpty else {
                return .failure(.unsupportedURLShape)
            }
            guard let id = UUID(uuidString: value) else {
                switch item.name {
                case "stable_workspace_id":
                    return .failure(.invalidIdentifier("stable_workspace"))
                case "stable_surface_id":
                    return .failure(.invalidIdentifier("stable_surface"))
                default:
                    return .failure(.unsupportedURLShape)
                }
            }
            switch item.name {
            case "stable_workspace_id":
                stableWorkspaceId = id
            case "stable_surface_id":
                stableSurfaceId = id
            default:
                return .failure(.unsupportedURLShape)
            }
        }
        return .success((workspaceId: stableWorkspaceId, surfaceId: stableSurfaceId))
    }
}

/// Compatibility spelling used by the macOS target and older package clients.
public typealias CMUXNavigationURLRequest = CmxNavigationURLRequest
/// Compatibility spelling used by the macOS target and older package clients.
public typealias CMUXNavigationURLParseError = CmxNavigationURLParseError
