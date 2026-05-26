import Foundation

public enum CmuxExtensionSidebarProviderID {
    public static let defaultWorkspaces = "cmux.sidebar.default"
}

public enum CmuxExtensionSidebarPresentation: String, Codable, Equatable, Sendable {
    case tree
    case browserStack = "browser-stack"
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
        subtitle: CmuxExtensionLocalizedText?,
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
        title: CmuxExtensionLocalizedText(
            key: "sidebar.provider.default.title",
            defaultValue: "Default Workspaces"
        ),
        subtitle: CmuxExtensionLocalizedText(
            key: "sidebar.provider.default.subtitle",
            defaultValue: "cmux"
        ),
        systemImageName: "list.bullet",
        isHostProvided: true
    )
}

public struct CmuxExtensionWorkspaceTreeSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var titleText: CmuxExtensionLocalizedText?
    public var subtitle: String?
    public var subtitleText: CmuxExtensionLocalizedText?
    public var systemImageName: String
    public var projectRootPath: String?
    public var workspaceIds: [UUID]

    public init(
        id: String,
        title: String,
        titleText: CmuxExtensionLocalizedText? = nil,
        subtitle: String?,
        subtitleText: CmuxExtensionLocalizedText? = nil,
        systemImageName: String,
        projectRootPath: String?,
        workspaceIds: [UUID]
    ) {
        self.id = id
        self.title = title
        self.titleText = titleText
        self.subtitle = subtitle
        self.subtitleText = subtitleText
        self.systemImageName = systemImageName
        self.projectRootPath = projectRootPath
        self.workspaceIds = workspaceIds
    }
}

public enum CmuxExtensionWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    case notes
    case browser
    @available(*, deprecated, message: "Use browser. pullRequest decodes as browser for legacy payloads.")
    case pullRequest

    public static let allCases: [CmuxExtensionWorkspacePopoverTab] = [.notes, .browser]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case Self.notes.rawValue:
            self = .notes
        case Self.browser.rawValue, "pullRequest":
            self = .browser
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown workspace popover tab: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .notes:
            try container.encode(Self.notes.rawValue)
        case .browser:
            try container.encode(Self.browser.rawValue)
        default:
            try container.encode(Self.browser.rawValue)
        }
    }
}

public enum CmuxExtensionWorkspaceRowAccessoryKind: String, Codable, Equatable, Sendable {
    case workspaceInspector
}

public struct CmuxExtensionWorkspaceRowAccessory: Codable, Equatable, Sendable {
    public var kind: CmuxExtensionWorkspaceRowAccessoryKind
    public var systemImageName: String
    public var defaultTab: CmuxExtensionWorkspacePopoverTab

    public init(
        kind: CmuxExtensionWorkspaceRowAccessoryKind,
        systemImageName: String,
        defaultTab: CmuxExtensionWorkspacePopoverTab
    ) {
        self.kind = kind
        self.systemImageName = systemImageName
        self.defaultTab = defaultTab
    }

    public static let inspector = CmuxExtensionWorkspaceRowAccessory(
        kind: .workspaceInspector,
        systemImageName: "ellipsis.circle",
        defaultTab: .notes
    )
}

public enum CmuxExtensionSidebarRelativeDateStyle: String, Codable, Equatable, Sendable {
    case compact
}

public enum CmuxExtensionSidebarRenderIconShape: String, Codable, Equatable, Sendable {
    case circle
    case roundedRectangle = "rounded-rectangle"
}

public struct CmuxExtensionSidebarRenderIcon: Codable, Equatable, Sendable {
    public var systemImageName: String?
    public var text: String?
    public var foregroundColorHex: String?
    public var backgroundColorHex: String?
    public var shape: CmuxExtensionSidebarRenderIconShape

    public init(
        systemImageName: String? = nil,
        text: String? = nil,
        foregroundColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        shape: CmuxExtensionSidebarRenderIconShape = .circle
    ) {
        self.systemImageName = systemImageName
        self.text = text
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.shape = shape
    }
}

public enum CmuxExtensionSidebarRenderText: Codable, Equatable, Sendable {
    case plain(String)
    case localized(CmuxExtensionLocalizedText)
    case relativeDate(Date, style: CmuxExtensionSidebarRelativeDateStyle)

    public var relativeDate: Date? {
        switch self {
        case .plain, .localized:
            return nil
        case .relativeDate(let date, _):
            return date
        }
    }
}

public struct CmuxExtensionSidebarRenderRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var workspaceId: UUID
    public var accessory: CmuxExtensionWorkspaceRowAccessory?
    public var subtitle: CmuxExtensionSidebarRenderText?
    public var trailingText: CmuxExtensionSidebarRenderText?
    public var leadingIcon: CmuxExtensionSidebarRenderIcon?

    public init(
        id: UUID,
        title: String,
        workspaceId: UUID,
        accessory: CmuxExtensionWorkspaceRowAccessory?,
        subtitle: CmuxExtensionSidebarRenderText? = nil,
        trailingText: CmuxExtensionSidebarRenderText? = nil,
        leadingIcon: CmuxExtensionSidebarRenderIcon? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.accessory = accessory
        self.subtitle = subtitle
        self.trailingText = trailingText
        self.leadingIcon = leadingIcon
    }
}

public struct CmuxExtensionSidebarRenderSection: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var treeSection: CmuxExtensionWorkspaceTreeSection
    public var rows: [CmuxExtensionSidebarRenderRow]

    public init(
        id: String,
        treeSection: CmuxExtensionWorkspaceTreeSection,
        rows: [CmuxExtensionSidebarRenderRow]
    ) {
        self.id = id
        self.treeSection = treeSection
        self.rows = rows
    }
}

public struct CmuxExtensionSidebarRenderModel: Codable, Equatable, Sendable {
    public var providerId: String
    public var snapshotSequence: UInt64
    public var sections: [CmuxExtensionSidebarRenderSection]
    public var presentation: CmuxExtensionSidebarPresentation

    public init(
        providerId: String,
        snapshotSequence: UInt64,
        sections: [CmuxExtensionSidebarRenderSection],
        presentation: CmuxExtensionSidebarPresentation = .tree
    ) {
        self.providerId = providerId
        self.snapshotSequence = snapshotSequence
        self.sections = sections
        self.presentation = presentation
    }

    private enum CodingKeys: String, CodingKey {
        case providerId
        case snapshotSequence
        case sections
        case presentation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decode(String.self, forKey: .providerId)
        snapshotSequence = try container.decode(UInt64.self, forKey: .snapshotSequence)
        sections = try container.decode([CmuxExtensionSidebarRenderSection].self, forKey: .sections)
        presentation = try container.decodeIfPresent(
            CmuxExtensionSidebarPresentation.self,
            forKey: .presentation
        ) ?? .tree
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerId, forKey: .providerId)
        try container.encode(snapshotSequence, forKey: .snapshotSequence)
        try container.encode(sections, forKey: .sections)
        try container.encode(presentation, forKey: .presentation)
    }
}

public extension CmuxExtensionSidebarRenderModel {
    var relativeTextDates: [Date] {
        sections.flatMap { section in
            section.rows.flatMap { row in
                [row.subtitle?.relativeDate, row.trailingText?.relativeDate].compactMap { $0 }
            }
        }
    }
}

public enum CmuxExtensionSidebarPresentationRequest: Codable, Equatable, Sendable {
    case openWorkspacePopover(workspaceId: UUID, preferredTab: CmuxExtensionWorkspacePopoverTab)
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: CmuxExtensionWorkspacePopoverTab)
    case openURL(String)
}

public struct CmuxExtensionSidebarWorkspaceMove: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var sourceSectionId: String?
    public var targetSectionId: String
    public var targetIndex: Int

    public init(
        workspaceId: UUID,
        sourceSectionId: String?,
        targetSectionId: String,
        targetIndex: Int
    ) {
        self.workspaceId = workspaceId
        self.sourceSectionId = sourceSectionId
        self.targetSectionId = targetSectionId
        self.targetIndex = targetIndex
    }
}

public enum CmuxExtensionSidebarMutation: Codable, Equatable, Sendable {
    case selectWorkspace(UUID)
    case closeWorkspace(UUID)
    case createWorktree(projectRootPath: String)
    case moveWorkspace(CmuxExtensionSidebarWorkspaceMove)
    case present(CmuxExtensionSidebarPresentationRequest)
}

public struct CmuxExtensionSidebarRenderContext: Codable, Equatable, Sendable {
    public var now: Date

    public init(now: Date) {
        self.now = now
    }

    public static var current: CmuxExtensionSidebarRenderContext {
        CmuxExtensionSidebarRenderContext(now: Date())
    }
}

public protocol CmuxExtensionSidebarProvider: Sendable {
    var descriptor: CmuxExtensionSidebarProviderDescriptor { get }

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel
}

public protocol CmuxExtensionSidebarContextualProvider: CmuxExtensionSidebarProvider {
    func render(snapshot: CmuxExtensionSidebarSnapshot, context: CmuxExtensionSidebarRenderContext) -> CmuxExtensionSidebarRenderModel
}

public protocol CmuxExtensionSidebarMutableProvider: CmuxExtensionSidebarContextualProvider {
    func handle(
        _ mutation: CmuxExtensionSidebarMutation,
        snapshot: CmuxExtensionSidebarSnapshot
    ) throws -> CmuxExtensionCommandResult
}

public extension CmuxExtensionSidebarProvider {
    func render(snapshot: CmuxExtensionSidebarSnapshot, context: CmuxExtensionSidebarRenderContext) -> CmuxExtensionSidebarRenderModel {
        render(snapshot: snapshot)
    }
}
