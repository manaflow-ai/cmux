import Foundation

/// Describes a browser panel that a mobile client can stream.
public struct MobileBrowserPanelDescriptor: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Owning workspace UUID string.
    public let workspaceID: String
    /// Current page URL, when one is available.
    public let url: String?
    /// Current page title, when one is available.
    public let title: String?
    /// Visible page width in AppKit points.
    public let pageWidth: Double
    /// Visible page height in AppKit points.
    public let pageHeight: Double
    /// Whether backward navigation is available.
    public let canGoBack: Bool
    /// Whether forward navigation is available.
    public let canGoForward: Bool
    /// Whether the page is loading.
    public let isLoading: Bool
    /// Current unresolved native dialog, when one exists at stream start.
    public let pendingDialog: MobileBrowserDialogEvent?

    /// Creates a browser panel descriptor.
    public init(
        panelID: String,
        workspaceID: String,
        url: String?,
        title: String?,
        pageWidth: Double,
        pageHeight: Double,
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        pendingDialog: MobileBrowserDialogEvent? = nil
    ) {
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.url = url
        self.title = title
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.pendingDialog = pendingDialog
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case workspaceID = "workspace_id"
        case url
        case title
        case pageWidth = "page_width"
        case pageHeight = "page_height"
        case canGoBack = "can_go_back"
        case canGoForward = "can_go_forward"
        case isLoading = "is_loading"
        case pendingDialog = "pending_dialog"
    }
}
