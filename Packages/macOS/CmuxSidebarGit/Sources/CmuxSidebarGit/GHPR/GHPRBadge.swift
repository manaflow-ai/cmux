public import Foundation

/// Immutable status badge projected into a workspace sidebar snapshot.
public struct GHPRBadge: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case pr
        case title
        case ci
        case review
        case unresolved
        case jira
        case draft
        case conflicts
        case updated
        case author
        case pinned
    }

    public let kind: Kind
    public let value: String
    public let icon: String
    public let colorHex: String?
    public let url: URL?

    public init(kind: Kind, value: String, icon: String, colorHex: String?, url: URL?) {
        self.kind = kind
        self.value = value
        self.icon = icon
        self.colorHex = colorHex
        self.url = url
    }

    public var key: String { "ghpr.\(kind.rawValue)" }
}
