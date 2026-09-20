import Foundation

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var isMuted: Bool
    var chromeVisibility: BrowserChromeVisibility? = nil
    var omnibarVisible: Bool? = nil
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
    /// True when the surface is a transparent internal cmux UI (e.g. the diff
    /// viewer). Restored so the surface comes back transparent, not opaque.
    var transparentBackground: Bool? = nil
    /// Diff viewer token + request path, when this browser surface hosts a diff viewer.
    /// Restored by re-registering the token with the app-owned `CmuxDiffViewerURLSchemeHandler`
    /// and navigating via the custom scheme, independent of the (possibly-dead) local HTTP server.
    var diffViewerToken: String? = nil
    var diffViewerRequestPath: String? = nil
    /// Per-panel provenance also survives Dock and closed-panel snapshots.
    var cloudResource: SurfaceResourceID? = nil

    init(
        urlString: String?,
        profileID: UUID?,
        shouldRenderWebView: Bool,
        pageZoom: Double,
        developerToolsVisible: Bool,
        isMuted: Bool = false,
        chromeVisibility: BrowserChromeVisibility? = nil,
        omnibarVisible: Bool? = nil,
        backHistoryURLStrings: [String]?,
        forwardHistoryURLStrings: [String]?,
        transparentBackground: Bool? = nil,
        diffViewerToken: String? = nil,
        diffViewerRequestPath: String? = nil,
        cloudResource: SurfaceResourceID? = nil
    ) {
        self.urlString = urlString
        self.profileID = profileID
        self.shouldRenderWebView = shouldRenderWebView
        self.pageZoom = pageZoom
        self.developerToolsVisible = developerToolsVisible
        self.isMuted = isMuted
        self.chromeVisibility = chromeVisibility
        self.omnibarVisible = omnibarVisible
        self.backHistoryURLStrings = backHistoryURLStrings
        self.forwardHistoryURLStrings = forwardHistoryURLStrings
        self.transparentBackground = transparentBackground
        self.diffViewerToken = diffViewerToken
        self.diffViewerRequestPath = diffViewerRequestPath
        self.cloudResource = cloudResource
    }

    private enum CodingKeys: String, CodingKey {
        case urlString
        case profileID
        case shouldRenderWebView
        case pageZoom
        case developerToolsVisible
        case isMuted
        case chromeVisibility
        case omnibarVisible
        case backHistoryURLStrings
        case forwardHistoryURLStrings
        case transparentBackground
        case diffViewerToken
        case diffViewerRequestPath
        case cloudResource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        shouldRenderWebView = try container.decode(Bool.self, forKey: .shouldRenderWebView)
        pageZoom = try container.decode(Double.self, forKey: .pageZoom)
        developerToolsVisible = try container.decode(Bool.self, forKey: .developerToolsVisible)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        chromeVisibility = try container.decodeIfPresent(BrowserChromeVisibility.self, forKey: .chromeVisibility)
        omnibarVisible = try container.decodeIfPresent(Bool.self, forKey: .omnibarVisible)
        backHistoryURLStrings = try container.decodeIfPresent([String].self, forKey: .backHistoryURLStrings)
        forwardHistoryURLStrings = try container.decodeIfPresent([String].self, forKey: .forwardHistoryURLStrings)
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground)
        diffViewerToken = try container.decodeIfPresent(String.self, forKey: .diffViewerToken)
        diffViewerRequestPath = try container.decodeIfPresent(String.self, forKey: .diffViewerRequestPath)
        cloudResource = try container.decodeIfPresent(SurfaceResourceID.self, forKey: .cloudResource)
    }
}
