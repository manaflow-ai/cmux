import CoreGraphics
import Foundation
import Bonsplit
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Panel snapshot model
struct SessionTerminalPanelSnapshot: Codable, Sendable {
    var workingDirectory: String?
    var scrollback: String?
    var agent: SessionRestorableAgentSnapshot?
    var tmuxStartCommand: String?
    var hibernation: SessionAgentHibernationSnapshot?
    var resumeBinding: SurfaceResumeBindingSnapshot?
    var textBoxDraft: SessionTextBoxInputDraftSnapshot?
    var isRemoteTerminal: Bool?
    var remotePTYSessionID: String?
    /// Whether the agent process was actively running when this snapshot was captured.
    /// Nil means unknown (legacy snapshots); treated as true for backwards compatibility.
    var wasAgentRunning: Bool?

    init(
        workingDirectory: String? = nil,
        scrollback: String? = nil,
        agent: SessionRestorableAgentSnapshot? = nil,
        tmuxStartCommand: String? = nil,
        hibernation: SessionAgentHibernationSnapshot? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        textBoxDraft: SessionTextBoxInputDraftSnapshot? = nil,
        isRemoteTerminal: Bool? = nil,
        remotePTYSessionID: String? = nil,
        wasAgentRunning: Bool? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.scrollback = scrollback
        self.agent = agent
        self.tmuxStartCommand = tmuxStartCommand
        self.hibernation = hibernation
        self.resumeBinding = resumeBinding
        self.textBoxDraft = textBoxDraft
        self.isRemoteTerminal = isRemoteTerminal
        self.remotePTYSessionID = remotePTYSessionID
        self.wasAgentRunning = wasAgentRunning
    }
}

struct SessionAgentHibernationSnapshot: Codable, Sendable {
    var hibernatedAt: TimeInterval
    var lastActivityAt: TimeInterval
}

struct SessionTextBoxInputDraftSnapshot: Codable, Equatable, Sendable {
    var isActive: Bool
    var parts: [SessionTextBoxInputDraftPart]
}

struct SessionTextBoxInputDraftPart: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case attachment
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case attachment
    }

    let kind: Kind
    let text: String?
    let attachment: SessionTextBoxInputAttachmentSnapshot?

    private init(kind: Kind, text: String?, attachment: SessionTextBoxInputAttachmentSnapshot?) {
        self.kind = kind
        self.text = text
        self.attachment = attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let attachment = try container.decodeIfPresent(
            SessionTextBoxInputAttachmentSnapshot.self,
            forKey: .attachment
        )

        switch kind {
        case .text:
            guard text != nil, attachment == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .text,
                    in: container,
                    debugDescription: "Text draft parts must contain text and no attachment."
                )
            }
        case .attachment:
            guard attachment != nil, text == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .attachment,
                    in: container,
                    debugDescription: "Attachment draft parts must contain an attachment and no text."
                )
            }
        }

        self.kind = kind
        self.text = text
        self.attachment = attachment
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(attachment, forKey: .attachment)
    }

    static func text(_ text: String) -> SessionTextBoxInputDraftPart {
        SessionTextBoxInputDraftPart(kind: .text, text: text, attachment: nil)
    }

    static func attachment(_ attachment: SessionTextBoxInputAttachmentSnapshot) -> SessionTextBoxInputDraftPart {
        SessionTextBoxInputDraftPart(kind: .attachment, text: nil, attachment: attachment)
    }
}

struct SessionTextBoxInputAttachmentSnapshot: Codable, Equatable, Sendable {
    var displayName: String
    var submissionText: String
    var submissionPath: String
    var localPath: String?
    var cleanupLocalPathWhenDisposed: Bool
}

struct SessionBrowserPanelSnapshot: Codable, Sendable {
    var urlString: String?
    var profileID: UUID?
    var shouldRenderWebView: Bool
    var pageZoom: Double
    var developerToolsVisible: Bool
    var isMuted: Bool
    var omnibarVisible: Bool? = nil
    var backHistoryURLStrings: [String]?
    var forwardHistoryURLStrings: [String]?
    /// True when the surface is a transparent internal cmux UI (e.g. the diff
    /// viewer). Restored so the surface comes back transparent, not opaque.
    var transparentBackground: Bool? = nil
    /// Diff viewer token + request path, when this browser surface hosts a diff
    /// viewer. Restored by re-registering the token with the app-owned
    /// `CmuxDiffViewerURLSchemeHandler` and navigating via the custom scheme,
    /// independent of the (possibly-dead) local HTTP server.
    var diffViewerToken: String? = nil
    var diffViewerRequestPath: String? = nil

    init(
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

    init(from decoder: Decoder) throws {
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
struct SessionMarkdownPanelSnapshot: Codable, Sendable {
    var filePath: String
}

struct SessionFilePreviewPanelSnapshot: Codable, Sendable {
    var filePath: String
}

struct SessionRightSidebarToolPanelSnapshot: Codable, Sendable {
    var mode: RightSidebarMode?

    init(mode: RightSidebarMode?) {
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .mode)
        self.mode = raw.flatMap { RightSidebarMode(rawValue: $0) }
    }
}

struct SessionProjectPanelSnapshot: Codable, Sendable {
    var projectPath: String
    var selectedNodePath: String?
    var activeTab: String?
    var selectedSchemeName: String?
    var selectedConfigurationName: String?

    init(
        projectPath: String,
        selectedNodePath: String? = nil,
        activeTab: String? = nil,
        selectedSchemeName: String? = nil,
        selectedConfigurationName: String? = nil
    ) {
        self.projectPath = projectPath
        self.selectedNodePath = selectedNodePath
        self.activeTab = activeTab
        self.selectedSchemeName = selectedSchemeName
        self.selectedConfigurationName = selectedConfigurationName
    }
}

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    var isRead: Bool
    var paneFlash: Bool?
    var clickAction: TerminalNotificationClickAction?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        isRead: Bool,
        paneFlash: Bool? = nil,
        clickAction: TerminalNotificationClickAction? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.clickAction = clickAction
    }

    init(notification: TerminalNotification) {
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            clickAction: notification.clickAction
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            clickAction: clickAction
        )
    }
}

struct SessionPanelSnapshot: Codable, Sendable {
    var id: UUID
    var type: PanelType
    var title: String?
    var customTitle: String?
    var directory: String?
    var isPinned: Bool
    var isManuallyUnread: Bool
    var hasUnreadIndicator: Bool? = nil
    var restoredUnreadContributesToWorkspace: Bool? = nil
    var notifications: [SessionNotificationSnapshot]? = nil
    var gitBranch: SessionGitBranchSnapshot?
    var listeningPorts: [Int]
    var ttyName: String?
    var terminal: SessionTerminalPanelSnapshot?
    var browser: SessionBrowserPanelSnapshot?
    var markdown: SessionMarkdownPanelSnapshot?
    var filePreview: SessionFilePreviewPanelSnapshot?
    var rightSidebarTool: SessionRightSidebarToolPanelSnapshot?
    var agentSession: SessionAgentSessionPanelSnapshot? = nil
    var project: SessionProjectPanelSnapshot?
}

