import AppKit
import CmuxFoundation
import SwiftUI

/// The resolved color shared by pane flashes and unread notification rings.
///
/// The setting store remains the only owner of the configured string. This
/// value validates one immutable snapshot before it reaches a renderer, so
/// AppKit layers and SwiftUI canvases never read ambient defaults or parse the
/// setting in their drawing loops.
struct WorkspaceAttentionColor: Equatable, Sendable {
    private let rgb: UInt32?

    init(configuredHex: String?) {
        self.rgb = Self.strictRGB(configuredHex)
    }

    var nsColor: NSColor {
        guard let rgb else {
            return WorkspaceAttentionCoordinator.notificationRingStyle.accent.strokeColor
        }
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func strictRGB(_ raw: String?) -> UInt32? {
        guard let raw else { return nil }
        let bytes = raw.utf8
        guard bytes.count == 7,
              bytes.first == 0x23,
              bytes.dropFirst().allSatisfy(isASCIIHexDigit) else { return nil }
        return UInt32(raw.dropFirst(), radix: 16)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30 ... 0x39, 0x41 ... 0x46, 0x61 ... 0x66:
            return true
        default:
            return false
        }
    }
}

/// The agent-state border resolved for one pane: the status that produced it
/// and the color that status paints.
///
/// The status travels with the color because pane chrome has to rank the
/// agent-state border against the unread notification ring, and the two are
/// only distinguishable by *why* a color was chosen — the no-agent neutral is
/// just another `WorkspaceAttentionColor`.
struct AgentPaneStateBorder: Equatable {
    let status: AgentStatus
    let color: WorkspaceAttentionColor

    /// The single ranking every pane renderer uses to pick its ring color.
    ///
    /// A live agent state outranks the unread ring. An agent posts its
    /// turn-complete notification in the same instant it reports `.idle`, so
    /// letting unread win would repaint every finished pane the same
    /// notification blue and the idle/needsInput/error colors would never be
    /// seen. The unread ring still outranks the no-agent neutral, so plain
    /// terminals keep their notification ring unchanged.
    static func ringColor(
        _ border: AgentPaneStateBorder?,
        showsUnreadRing: Bool,
        unreadColor: @autoclosure () -> NSColor
    ) -> NSColor? {
        if let border, border.status != .none { return border.color.nsColor }
        if showsUnreadRing { return unreadColor() }
        return border?.color.nsColor
    }
}

extension EnvironmentValues {
    @Entry var workspaceAttentionColor = WorkspaceAttentionColor(configuredHex: nil)

    /// The resolved agent-state border for the pane subtree below this value,
    /// or `nil` when no agent state should color the pane.
    ///
    /// Carried through the environment rather than as a view parameter so the
    /// border reaches `GhosttyTerminalView` without threading a new argument
    /// through `PanelContentView` and `TerminalPanelView`.
    @Entry var agentPaneStateColor: AgentPaneStateBorder?
}

#if DEBUG
extension NSColor {
    /// `#RRGGBB` for debug logs. Dynamic catalog colors (`.systemBlue`) have no
    /// components until they are converted, so convert before reading.
    var debugRingHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "unconvertible" }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
#endif
