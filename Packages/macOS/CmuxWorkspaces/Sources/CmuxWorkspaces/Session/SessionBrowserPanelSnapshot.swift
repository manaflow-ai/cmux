public import Foundation

/// Persisted state for a browser surface inside a session snapshot.
///
/// A pure leaf value carrying the surface's URL, profile, zoom, devtools/mute
/// flags, navigation history, and the diff-viewer token + request path used to
/// restore a transparent internal cmux UI surface. The on-disk wire format is
/// owned by the app's session snapshot; encoding stays byte-identical to the
/// legacy app-target definition (explicit `CodingKeys` over the same stored
/// properties, with the same optional-default decode semantics).
public struct SessionBrowserPanelSnapshot: Codable, Sendable {
    /// The surface's current URL, when one is loaded.
    public var urlString: String?
    /// The browser profile backing this surface, when assigned.
    public var profileID: UUID?
    /// Whether the web view should render on restore.
    public var shouldRenderWebView: Bool
    /// The surface's page zoom factor.
    public var pageZoom: Double
    /// Whether the developer tools panel was visible.
    public var developerToolsVisible: Bool
    /// Whether the surface's audio was muted.
    public var isMuted: Bool
    /// Whether the omnibar was visible. Absent in legacy snapshots.
    public var omnibarVisible: Bool? = nil
    /// Back-navigation history URLs, most-recent last.
    public var backHistoryURLStrings: [String]?
    /// Forward-navigation history URLs.
    public var forwardHistoryURLStrings: [String]?
    /// True when the surface is a transparent internal cmux UI (e.g. the diff
    /// viewer). Restored so the surface comes back transparent, not opaque.
    public var transparentBackground: Bool? = nil
    /// Diff viewer token + request path, when this browser surface hosts a diff
    /// viewer. Restored by re-registering the token with the app-owned
    /// `CmuxDiffViewerURLSchemeHandler` and navigating via the custom scheme,
    /// independent of the (possibly-dead) local HTTP server.
    public var diffViewerToken: String? = nil
    /// The diff viewer's request path, paired with `diffViewerToken`.
    public var diffViewerRequestPath: String? = nil

    /// Creates a browser panel snapshot from explicit components.
    public init(
        urlString: String?,
        profileID: UUID?,
        shouldRenderWebView: Bool,
        pageZoom: Double,
        developerToolsVisible: Bool,
        isMuted: Bool = false,
        omnibarVisible: Bool? = nil,
        backHistoryURLStrings: [String]?,
        forwardHistoryURLStrings: [String]?,
        transparentBackground: Bool? = nil,
        diffViewerToken: String? = nil,
        diffViewerRequestPath: String? = nil
    ) {
        self.urlString = urlString
        self.profileID = profileID
        self.shouldRenderWebView = shouldRenderWebView
        self.pageZoom = pageZoom
        self.developerToolsVisible = developerToolsVisible
        self.isMuted = isMuted
        self.omnibarVisible = omnibarVisible
        self.backHistoryURLStrings = backHistoryURLStrings
        self.forwardHistoryURLStrings = forwardHistoryURLStrings
        self.transparentBackground = transparentBackground
        self.diffViewerToken = diffViewerToken
        self.diffViewerRequestPath = diffViewerRequestPath
    }

    private enum CodingKeys: String, CodingKey {
        case urlString
        case profileID
        case shouldRenderWebView
        case pageZoom
        case developerToolsVisible
        case isMuted
        case omnibarVisible
        case backHistoryURLStrings
        case forwardHistoryURLStrings
        case transparentBackground
        case diffViewerToken
        case diffViewerRequestPath
    }

    /// Decodes a browser panel snapshot, defaulting `isMuted` to `false` for
    /// legacy snapshots that predate the mute flag.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        shouldRenderWebView = try container.decode(Bool.self, forKey: .shouldRenderWebView)
        pageZoom = try container.decode(Double.self, forKey: .pageZoom)
        developerToolsVisible = try container.decode(Bool.self, forKey: .developerToolsVisible)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        omnibarVisible = try container.decodeIfPresent(Bool.self, forKey: .omnibarVisible)
        backHistoryURLStrings = try container.decodeIfPresent([String].self, forKey: .backHistoryURLStrings)
        forwardHistoryURLStrings = try container.decodeIfPresent([String].self, forKey: .forwardHistoryURLStrings)
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground)
        diffViewerToken = try container.decodeIfPresent(String.self, forKey: .diffViewerToken)
        diffViewerRequestPath = try container.decodeIfPresent(String.self, forKey: .diffViewerRequestPath)
    }
}
