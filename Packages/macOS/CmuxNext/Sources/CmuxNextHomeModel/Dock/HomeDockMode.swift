import Foundation

/// The two views of the docked Home: the sidebar's Home entry (`messages`) and its Channels entry
/// (`channels`), selected with `home.switchView` (hq-6d cx-frn2y).
public enum HomeDockMode: String, CaseIterable, Sendable {
    case messages, channels

    public var other: HomeDockMode { self == .messages ? .channels : .messages }

    /// Refusals of `home.switchView` and of the page's `cmux.host.home.switchView`.
    public static var invalidViewMessage: String {
        String(localized: "homeDock.switch.invalidView", defaultValue: "Home has two views: messages and channels.", bundle: .module)
    }

    public static var channelsOffMessage: String {
        String(localized: "homeDock.switch.channelsOff", defaultValue: "Channels is off. Turn it on with Enable Channels in the command palette.",
               bundle: .module)
    }

    public static var classicMessage: String {
        String(localized: "homeDock.switch.classic", defaultValue: "Classic Home has only the Messages view.", bundle: .module)
    }
}

/// The selection a switch carries over (the permalink's parts).
public struct HomeDockSelection: Equatable, Sendable {
    public var conversation: String
    public var message: String?

    public init(conversation: String, message: String? = nil) {
        self.conversation = conversation
        self.message = message
    }

    /// The page route of the selection (hq-ec's hash contract, COORD.md).
    public var route: String { "/conversation/\(conversation)" + (message.map { "/message/\($0)" } ?? "") }

    /// A conversation or message id from a page or a caller: only the permalink grammar's characters
    /// (letters, digits, `_`, `-`; at most 128), so it can only ever name an id in a route.
    public nonisolated static func isLinkID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
            && id.allSatisfy(\.isASCII)
    }
}
