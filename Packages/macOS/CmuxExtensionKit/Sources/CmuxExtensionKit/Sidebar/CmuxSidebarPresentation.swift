import Foundation

/// A value-only sidebar tree sent from an extension process to cmux for native
/// rendering. Extensions own content and action identifiers; cmux owns AppKit
/// views, accessibility, and event routing.
public struct CmuxSidebarPresentation: Codable, Equatable, Sendable {
    public var root: CmuxSidebarPresentationNode

    public init(root: CmuxSidebarPresentationNode) {
        self.root = root
    }
}

public indirect enum CmuxSidebarPresentationNode: Codable, Equatable, Sendable {
    case text(String, style: CmuxSidebarPresentationTextStyle = .body)
    case symbol(String, color: CmuxSidebarPresentationColor = .secondary)
    case button(CmuxSidebarPresentationButton)
    case stack(
        axis: CmuxSidebarPresentationAxis,
        spacing: Double,
        children: [CmuxSidebarPresentationNode]
    )
    case scroll(CmuxSidebarPresentationNode)
    case spacer(minLength: Double = 0)
    case divider
    case progress
    case inset(CmuxSidebarPresentationInsets, CmuxSidebarPresentationNode)
    case panel(CmuxSidebarPresentationNode)
    case empty
}

public enum CmuxSidebarPresentationAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
    case depth
}

public enum CmuxSidebarPresentationColor: String, Codable, Equatable, Sendable {
    case primary
    case secondary
    case accent
    case error
}

public enum CmuxSidebarPresentationFontWeight: String, Codable, Equatable, Sendable {
    case regular
    case medium
    case semibold
}

public struct CmuxSidebarPresentationTextStyle: Codable, Equatable, Sendable {
    public var size: Double
    public var weight: CmuxSidebarPresentationFontWeight
    public var color: CmuxSidebarPresentationColor
    public var maximumLineCount: Int?

    public init(
        size: Double = 12,
        weight: CmuxSidebarPresentationFontWeight = .regular,
        color: CmuxSidebarPresentationColor = .primary,
        maximumLineCount: Int? = nil
    ) {
        self.size = size
        self.weight = weight
        self.color = color
        self.maximumLineCount = maximumLineCount
    }

    public static let body = Self()
    public static let secondary = Self(size: 11, color: .secondary)
    public static let heading = Self(size: 14, weight: .semibold)
}

public struct CmuxSidebarPresentationButton: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var systemImageName: String?
    public var isEnabled: Bool
    public var help: String?

    public init(
        id: String,
        title: String,
        systemImageName: String? = nil,
        isEnabled: Bool = true,
        help: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
        self.isEnabled = isEnabled
        self.help = help
    }
}

public struct CmuxSidebarPresentationInsets: Codable, Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static func all(_ value: Double) -> Self {
        Self(top: value, leading: value, bottom: value, trailing: value)
    }
}
