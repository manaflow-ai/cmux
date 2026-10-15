public import Foundation

/// A JavaScript dialog a page opened (`alert`, `confirm`, `prompt`,
/// `beforeunload`).
public struct BrowserPageJavaScriptDialog: Equatable, Hashable, Sendable {
    /// The dialog type.
    public enum Kind: Equatable, Hashable, Sendable {
        /// `alert(message)`.
        case alert
        /// `confirm(message)`.
        case confirm
        /// `prompt(message, defaultText)`.
        case prompt(defaultText: String?)
        /// A `beforeunload` "Leave page?" confirmation.
        case beforeUnload(isReload: Bool)
    }

    /// The dialog type.
    public var kind: Kind
    /// The message the page passed.
    public var message: String
    /// The frame origin that opened the dialog.
    public var origin: URL?

    /// Creates a dialog description.
    /// - Parameters:
    ///   - kind: The dialog type.
    ///   - message: The page's message.
    ///   - origin: The opening frame's origin.
    public init(kind: Kind, message: String, origin: URL?) {
        self.kind = kind
        self.message = message
        self.origin = origin
    }
}
