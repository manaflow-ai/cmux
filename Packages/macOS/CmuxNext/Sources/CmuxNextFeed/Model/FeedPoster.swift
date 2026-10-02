public import Foundation

/// Who posted an item (feed.md 3.2). `label` and `harness` are what the
/// poster declared; the rest comes from its authenticated principal.
public nonisolated struct FeedPoster: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        case agent
        case harness
        case app
        case server
        case vm
        case automation
        case integration
        case system
    }

    public var kind: Kind
    /// The poster's own label (a workspace, an app, a program name).
    public var label: String
    /// The agent harness, a product name shown as is ("Claude Code").
    public var harness: String?
    public var identity: String?
    public var host: String?

    public init(kind: Kind, label: String, harness: String? = nil, identity: String? = nil, host: String? = nil) {
        self.kind = kind
        self.label = label
        self.harness = harness
        self.identity = identity
        self.host = host
    }

    /// "Claude Code · api-server", or the label alone.
    public var displayLabel: String {
        guard let harness, !harness.isEmpty else { return label }
        return label.isEmpty ? harness : "\(harness) · \(label)"
    }
}

/// A reference to content too large for the body (bytes live with the owner).
public nonisolated struct FeedAttachment: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var mime: String
    public var size: Int
    /// Inline text the mock or the client already fetched (a diff preview).
    public var text: String?

    public init(id: String, name: String, mime: String, size: Int, text: String? = nil) {
        self.id = id
        self.name = name
        self.mime = mime
        self.size = size
        self.text = text
    }

    public var isDiff: Bool { mime == "text/x-diff" || mime == "text/x-patch" || name.hasSuffix(".diff") || name.hasSuffix(".patch") }
}

/// A poster-defined button. With `answer`, it answers the request with that
/// value; without, it only opens the context.
public nonisolated struct FeedAction: Sendable, Equatable, Hashable, Identifiable {
    public enum Style: String, Sendable, Equatable, Hashable {
        case `default`
        case primary
        case destructive
    }

    public var id: String
    public var label: String
    public var style: Style
    public var answer: FeedJSON?

    public init(id: String, label: String, style: Style = .default, answer: FeedJSON? = nil) {
        self.id = id
        self.label = label
        self.style = style
        self.answer = answer
    }
}
