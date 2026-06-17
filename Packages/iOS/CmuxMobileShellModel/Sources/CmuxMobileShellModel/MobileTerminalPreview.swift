import Foundation

/// A lightweight, `Sendable` snapshot of a single terminal inside a workspace.
///
/// Carries the terminal identity, display name, readiness/focus flags, and the
/// optional viewport-fit geometry the UI uses to draw the visible-area borders.
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
    /// The cmux device UUID of the Mac that owns this terminal, matching the
    /// owning ``MobileWorkspacePreview/deviceId``. Empty (`""`) means
    /// "unscoped" — the single-Mac legacy behavior. In the unified multi-Mac
    /// list this is stamped with the owning Mac's id so two Macs with colliding
    /// bare terminal ids stay distinguishable; the wire id (``id``) stays
    /// Mac-local and `deviceId` selects which client byte input is routed to.
    public var deviceId: String
    /// The terminal's user-facing display name.
    public var name: String
    /// Whether the terminal surface is ready to receive input and render output.
    public var isReady: Bool
    /// Whether the terminal currently holds focus in the shell.
    public var isFocused: Bool
    /// The negotiated viewport fit, when the remote has reported one.
    public var viewportFit: MobileTerminalViewportFit?

    /// Creates a terminal preview.
    /// - Parameters:
    ///   - id: The terminal's stable identifier.
    ///   - deviceId: The owning Mac's cmux device UUID. Defaults to `""`
    ///     (unscoped / single-Mac), so existing construction and tests compile
    ///     unchanged.
    ///   - name: The terminal's user-facing display name.
    ///   - isReady: Whether the terminal surface is ready. Defaults to `true`.
    ///   - isFocused: Whether the terminal currently holds focus. Defaults to `false`.
    ///   - viewportFit: The negotiated viewport fit, if any. Defaults to `nil`.
    public init(
        id: ID,
        deviceId: String = "",
        name: String,
        isReady: Bool = true,
        isFocused: Bool = false,
        viewportFit: MobileTerminalViewportFit? = nil
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.isReady = isReady
        self.isFocused = isFocused
        self.viewportFit = viewportFit
    }
}
