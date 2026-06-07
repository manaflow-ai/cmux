import Foundation

/// A lightweight, `Sendable` snapshot of a remote workspace shown in the mobile shell.
///
/// This is a pure value model: it carries the workspace identity, display name, and
/// the ordered list of its terminals. It is decoupled from any connection, RPC, or
/// rendering concern so that both the domain coordinators and the SwiftUI layer can
/// consume the same immutable shape.
public struct MobileWorkspacePreview: Identifiable, Equatable, Sendable {
    /// A stable, string-backed identifier for a ``MobileWorkspacePreview``.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        /// The underlying workspace identifier string.
        public var rawValue: String

        /// Creates an identifier from its raw string value.
        /// - Parameter rawValue: The backing workspace identifier.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates an identifier from a string literal.
        /// - Parameter value: The backing workspace identifier.
        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    /// The workspace's stable identifier.
    ///
    /// Identifiers are only guaranteed unique **within** a single Mac. Two paired
    /// Macs can surface colliding ids (synthetic preview ids especially), so any
    /// lookup that spans the aggregated multi-Mac list must scope by
    /// ``sourceMacDeviceID`` as well, never by ``id`` alone.
    public var id: ID
    /// The workspace's user-facing display name.
    public var name: String
    /// Whether the workspace is pinned on the Mac. Pinned workspaces sort to the
    /// top of the mobile list.
    public var isPinned: Bool
    /// The terminals contained in the workspace, in display order.
    public var terminals: [MobileTerminalPreview]
    /// Stable identifier of the paired Mac this workspace was sourced from.
    ///
    /// Tags each workspace with its owning device so the aggregated all-devices
    /// list can group by Mac and route input/replay/viewport to the correct
    /// Mac's client. Empty for synthetic preview workspaces with no real device.
    public var sourceMacDeviceID: String
    /// Human-readable name of the paired Mac this workspace was sourced from.
    ///
    /// Drives the per-Mac section header in the aggregated list. Falls back to
    /// the device id, or a generic label, when the Mac advertised no name.
    public var sourceMacDisplayName: String

    /// Creates a workspace preview.
    /// - Parameters:
    ///   - id: The workspace's stable identifier.
    ///   - name: The workspace's user-facing display name.
    ///   - isPinned: Whether the workspace is pinned on the Mac. Defaults to `false`.
    ///   - terminals: The terminals contained in the workspace, in display order.
    ///   - sourceMacDeviceID: Stable identifier of the owning paired Mac. Empty
    ///     for synthetic preview workspaces with no real device. Defaults to `""`.
    ///   - sourceMacDisplayName: Human-readable name of the owning paired Mac.
    ///     Defaults to `""`.
    public init(
        id: ID,
        name: String,
        isPinned: Bool = false,
        terminals: [MobileTerminalPreview],
        sourceMacDeviceID: String = "",
        sourceMacDisplayName: String = ""
    ) {
        self.id = id
        self.name = name
        self.isPinned = isPinned
        self.terminals = terminals
        self.sourceMacDeviceID = sourceMacDeviceID
        self.sourceMacDisplayName = sourceMacDisplayName
    }
}
