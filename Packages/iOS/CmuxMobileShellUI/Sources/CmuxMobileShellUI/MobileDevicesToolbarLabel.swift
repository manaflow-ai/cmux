#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The shared Devices toolbar glyph. The warning is intentionally a small
/// standard SF Symbol overlay so the action remains recognizable while making
/// a blocked Mac discoverable before the user opens the Computers sheet.
struct MobileDevicesToolbarLabel: View {
    /// A gate rejection observed by the shell store. The list-auth projection
    /// is also checked here because it can identify an outdated or unverified
    /// Mac before a connection attempt is made.
    let hasGateWarning: Bool

    private var showsWarning: Bool {
        Self.warningVisible(
            hasGateWarning: hasGateWarning,
            hasOutdatedListAuth: MobileMacListAuthState.shared.entriesByDeviceID.values
                .contains(where: \.isOutdated),
            hasUnverifiedListAuth: MobileMacListAuthState.shared.entriesByDeviceID.values
                .contains(where: { $0.status == "seeded" })
        )
    }

    static func warningVisible(
        hasGateWarning: Bool,
        hasOutdatedListAuth: Bool,
        hasUnverifiedListAuth: Bool = false
    ) -> Bool {
        hasGateWarning || hasOutdatedListAuth || hasUnverifiedListAuth
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "desktopcomputer")
            if showsWarning {
                // Keep the toolbar signal subordinate to the Computers glyph.
                // The full orange triangle remains in each Mac row and detail
                // section, where there is room for its explanation. A small
                // status dot avoids making the toolbar button look like it has
                // two competing icons.
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(.background, lineWidth: 1.5)
                    }
                    .offset(x: 4, y: -4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "mobile.connections.title",
            defaultValue: "Computers"
        ))
        .accessibilityValue(
            showsWarning
                ? L10n.string(
                    "computers.version.outdated.title",
                    defaultValue: "Mac update required"
                )
                : ""
        )
        .accessibilityIdentifier("MobileWorkspaceDevicesButtonIcon")
    }
}
#endif
