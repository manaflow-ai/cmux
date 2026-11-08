import CmuxSurfaceCatalogModel
import Foundation
import CmuxBrowser

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
    /// WebKit session state (back/forward list and scroll positions), so the
    /// first load after relaunch restores the page instead of reloading it.
    /// Omitted for private profiles, form submissions and oversized state.
    var interactionState: Data? = nil
    /// Whether the user pinned the page to stay active while hidden. Omitted
    /// when not pinned.
    var keepsPageActive: Bool? = nil
    /// The team that owns ``cloudResource``'s machine. Absent in snapshots
    /// written before multi-team Cloud; restore then adopts the selected team.
    var cloudTeamID: String? = nil

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
        cloudResource: SurfaceResourceID? = nil,
        interactionState: Data? = nil,
        keepsPageActive: Bool? = nil,
        cloudTeamID: String? = nil
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
        self.interactionState = interactionState
        self.keepsPageActive = keepsPageActive
        self.cloudTeamID = cloudResource == nil ? nil : cloudTeamID
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
        case interactionState
        case keepsPageActive
        case cloudTeamID
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
        interactionState = try container.decodeIfPresent(Data.self, forKey: .interactionState)
        keepsPageActive = try container.decodeIfPresent(Bool.self, forKey: .keepsPageActive)
        cloudTeamID = try container.decodeIfPresent(String.self, forKey: .cloudTeamID)
    }
}
