import Foundation

/// A lightweight, `Sendable` snapshot of a single terminal inside a workspace.
///
/// Carries the terminal identity, display name, readiness/focus/close flags, and
/// the optional viewport-fit geometry the UI uses to draw the visible-area borders.
public struct MobileTerminalPreview: Identifiable, Equatable, Sendable {
    /// A stable, string-backed identifier for a ``MobileTerminalPreview``.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        /// The underlying terminal identifier string.
        public var rawValue: String

        /// Creates an identifier from its raw string value.
        /// - Parameter rawValue: The backing terminal identifier.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates an identifier from a string literal.
        /// - Parameter value: The backing terminal identifier.
        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    /// The terminal's stable identifier.
    public var id: ID
    /// The terminal's user-facing display name.
    public var name: String
    /// Whether the terminal surface is ready to receive input and render output.
    public var isReady: Bool
    /// Whether the terminal currently holds focus in the shell.
    public var isFocused: Bool
    /// Whether the Mac will accept a non-interactive close request for this terminal.
    public var canClose: Bool
    /// The negotiated viewport fit, when the remote has reported one.
    public var viewportFit: MobileTerminalViewportFit?

    /// Creates a terminal preview.
    /// - Parameters:
    ///   - id: The terminal's stable identifier.
    ///   - name: The terminal's user-facing display name.
    ///   - isReady: Whether the terminal surface is ready. Defaults to `true`.
    ///   - isFocused: Whether the terminal currently holds focus. Defaults to `false`.
    ///   - canClose: Whether a non-interactive close request is allowed. Defaults to `true`.
    ///   - viewportFit: The negotiated viewport fit, if any. Defaults to `nil`.
    public init(
        id: ID,
        name: String,
        isReady: Bool = true,
        isFocused: Bool = false,
        canClose: Bool = true,
        viewportFit: MobileTerminalViewportFit? = nil
    ) {
        self.id = id
        self.name = name
        self.isReady = isReady
        self.isFocused = isFocused
        self.canClose = canClose
        self.viewportFit = viewportFit
    }
}
