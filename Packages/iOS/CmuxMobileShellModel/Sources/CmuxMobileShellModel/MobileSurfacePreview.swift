public import CMUXMobileCore
import Foundation

/// A lightweight snapshot of any Mac-rendered workspace surface.
public struct MobileSurfacePreview: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        /// The Mac-local surface identifier.
        public var rawValue: String
        /// Creates an identifier from a wire value.
        public init(rawValue: String) { self.rawValue = rawValue }
        /// Creates an identifier from a string literal.
        public init(stringLiteral value: String) { rawValue = value }
    }

    /// Known surface kinds plus a forward-compatible unknown case.
    public enum Kind: Equatable, Hashable, Sendable {
        /// Known surface kinds.
        case terminal, browser, markdown, filePreview, rightSidebarTool, customSidebar
        /// Additional known surface kinds.
        case agentSession, project, extensionBrowser, todo, cloudVMLoading
        /// A kind introduced by a newer Mac.
        case other(String)

        /// Classifies an open wire kind without discarding unknown values.
        public init(rawValue: String) {
            switch MobileSurfaceKind(rawValue: rawValue) {
            case .terminal: self = .terminal
            case .browser: self = .browser
            case .markdown: self = .markdown
            case .filePreview: self = .filePreview
            case .rightSidebarTool: self = .rightSidebarTool
            case .customSidebar: self = .customSidebar
            case .agentSession: self = .agentSession
            case .project: self = .project
            case .extensionBrowser: self = .extensionBrowser
            case .todo: self = .todo
            case .cloudVMLoading: self = .cloudVMLoading
            default: self = .other(rawValue)
            }
        }

        /// The original open wire value.
        public var rawValue: String {
            switch self {
            case .terminal: MobileSurfaceKind.terminal.rawValue
            case .browser: MobileSurfaceKind.browser.rawValue
            case .markdown: MobileSurfaceKind.markdown.rawValue
            case .filePreview: MobileSurfaceKind.filePreview.rawValue
            case .rightSidebarTool: MobileSurfaceKind.rightSidebarTool.rawValue
            case .customSidebar: MobileSurfaceKind.customSidebar.rawValue
            case .agentSession: MobileSurfaceKind.agentSession.rawValue
            case .project: MobileSurfaceKind.project.rawValue
            case .extensionBrowser: MobileSurfaceKind.extensionBrowser.rawValue
            case .todo: MobileSurfaceKind.todo.rawValue
            case .cloudVMLoading: MobileSurfaceKind.cloudVMLoading.rawValue
            case let .other(value): value
            }
        }

        /// Whether this kind is a terminal rendered by the existing terminal path.
        public var isTerminal: Bool { self == .terminal }
    }

    /// Stable Mac-local surface identifier.
    public let id: ID
    /// Open, forward-compatible surface kind.
    public let kind: Kind
    /// User-facing surface title.
    public let title: String
    /// Backing path for file-oriented surfaces, when supplied by the Mac.
    public let filePath: String?
    /// Bounded checklist/status data for a todo surface.
    public let todo: MobileTodoSnapshot?

    /// Creates a surface preview from projected wire data.
    public init(
        id: ID,
        kind: Kind,
        title: String,
        filePath: String? = nil,
        todo: MobileTodoSnapshot? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.filePath = filePath
        self.todo = todo
    }
}
