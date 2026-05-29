import Foundation

public struct CMUXExtensionAPIVersion: Codable, Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let sidebarV1 = CMUXExtensionAPIVersion(major: 1, minor: 0)

    public static func < (lhs: CMUXExtensionAPIVersion, rhs: CMUXExtensionAPIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}

public enum CMUXExtensionKind: String, Codable, CaseIterable, Equatable, Sendable {
    case sidebar
}

public struct CMUXExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: CMUXExtensionKind
    public var minimumAPIVersion: CMUXExtensionAPIVersion
    public var requestedScopes: [CMUXExtensionScope]

    public init(
        id: String,
        displayName: String,
        kind: CMUXExtensionKind = .sidebar,
        minimumAPIVersion: CMUXExtensionAPIVersion = .sidebarV1,
        requestedScopes: [CMUXExtensionScope] = [.workspaceMetadata]
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.minimumAPIVersion = minimumAPIVersion
        self.requestedScopes = requestedScopes
    }
}

public enum CMUXExtensionScope: String, Codable, CaseIterable, Equatable, Sendable {
    case workspaceMetadata
    case workspacePaths
    case notifications
    case networkPorts
    case pullRequests
}

public struct CMUXSidebarSnapshot: Codable, Equatable, Sendable {
    public var apiVersion: CMUXExtensionAPIVersion
    public var sequence: UInt64
    public var windowID: UUID?
    public var selectedWorkspaceID: UUID?
    public var workspaces: [CMUXSidebarWorkspace]

    public init(
        apiVersion: CMUXExtensionAPIVersion = .sidebarV1,
        sequence: UInt64,
        windowID: UUID? = nil,
        selectedWorkspaceID: UUID?,
        workspaces: [CMUXSidebarWorkspace]
    ) {
        self.apiVersion = apiVersion
        self.sequence = sequence
        self.windowID = windowID
        self.selectedWorkspaceID = selectedWorkspaceID
        self.workspaces = workspaces
    }
}

public struct CMUXSidebarWorkspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String?
    public var isPinned: Bool
    public var rootPath: String?
    public var projectRootPath: String?
    public var gitBranch: String?
    public var unreadCount: Int
    public var latestNotification: String?
    public var listeningPorts: [Int]
    public var pullRequestURLs: [String]

    public init(
        id: UUID,
        title: String,
        detail: String? = nil,
        isPinned: Bool = false,
        rootPath: String? = nil,
        projectRootPath: String? = nil,
        gitBranch: String? = nil,
        unreadCount: Int = 0,
        latestNotification: String? = nil,
        listeningPorts: [Int] = [],
        pullRequestURLs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isPinned = isPinned
        self.rootPath = rootPath
        self.projectRootPath = projectRootPath
        self.gitBranch = gitBranch
        self.unreadCount = unreadCount
        self.latestNotification = latestNotification
        self.listeningPorts = listeningPorts
        self.pullRequestURLs = pullRequestURLs
    }
}

public enum CMUXSidebarAction: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case openURL(String)
}

public struct CMUXExtensionActionResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String?

    public init(accepted: Bool, message: String? = nil) {
        self.accepted = accepted
        self.message = message
    }

    public static let accepted = CMUXExtensionActionResult(accepted: true)
}

public protocol CMUXSidebarExtension: Sendable {
    var manifest: CMUXExtensionManifest { get }

    func makeInitialSnapshot() async throws -> CMUXSidebarSnapshot
    func handle(_ action: CMUXSidebarAction) async throws -> CMUXExtensionActionResult
}

public struct CMUXSidebarHostClient: Sendable {
    public var snapshot: @Sendable () async throws -> CMUXSidebarSnapshot
    public var dispatch: @Sendable (CMUXSidebarAction) async throws -> CMUXExtensionActionResult

    public init(
        snapshot: @escaping @Sendable () async throws -> CMUXSidebarSnapshot,
        dispatch: @escaping @Sendable (CMUXSidebarAction) async throws -> CMUXExtensionActionResult
    ) {
        self.snapshot = snapshot
        self.dispatch = dispatch
    }
}

public enum CMUXExtensionValidationError: Error, Equatable, Sendable {
    case unsupportedKind(CMUXExtensionKind)
    case unsupportedAPIVersion(requested: CMUXExtensionAPIVersion, supported: CMUXExtensionAPIVersion)
    case emptyIdentifier
    case emptyDisplayName
}

public enum CMUXExtensionValidator {
    public static func validateSidebarManifest(
        _ manifest: CMUXExtensionManifest,
        supportedAPIVersion: CMUXExtensionAPIVersion = .sidebarV1
    ) throws {
        guard manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CMUXExtensionValidationError.emptyIdentifier
        }
        guard manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CMUXExtensionValidationError.emptyDisplayName
        }
        guard manifest.kind == .sidebar else {
            throw CMUXExtensionValidationError.unsupportedKind(manifest.kind)
        }
        guard manifest.minimumAPIVersion <= supportedAPIVersion else {
            throw CMUXExtensionValidationError.unsupportedAPIVersion(
                requested: manifest.minimumAPIVersion,
                supported: supportedAPIVersion
            )
        }
    }
}

// Compatibility names used only by the existing cmux app while the old prototype
// sidebar is removed in smaller follow-up steps.
public enum CmuxExtensionSidebarProviderID {
    public static let defaultWorkspaces = "cmux.sidebar.default"
}

public struct CmuxExtensionLocalizedText: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var defaultValue: String

    public init(key: String, defaultValue: String) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

public struct CmuxExtensionSidebarProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: CmuxExtensionLocalizedText
    public var subtitle: CmuxExtensionLocalizedText?
    public var systemImageName: String
    public var isHostProvided: Bool

    public init(
        id: String,
        title: CmuxExtensionLocalizedText,
        subtitle: CmuxExtensionLocalizedText? = nil,
        systemImageName: String,
        isHostProvided: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.isHostProvided = isHostProvided
    }

    public static let defaultWorkspaces = CmuxExtensionSidebarProviderDescriptor(
        id: CmuxExtensionSidebarProviderID.defaultWorkspaces,
        title: CmuxExtensionLocalizedText(key: "sidebar.provider.default.title", defaultValue: "Default Workspaces"),
        subtitle: CmuxExtensionLocalizedText(key: "sidebar.provider.default.subtitle", defaultValue: "cmux"),
        systemImageName: "list.bullet",
        isHostProvided: true
    )
}

public protocol CmuxExtensionSidebarProvider: Sendable {
    var descriptor: CmuxExtensionSidebarProviderDescriptor { get }
}
