#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The shared Devices toolbar glyph. The warning is intentionally a small
/// standard SF Symbol overlay so the action remains recognizable while making
/// a blocked Mac discoverable before the user opens the Computers sheet.
struct MobileDevicesToolbarLabel: View {
    /// A gate rejection observed by the shell store. The list-auth projection
    /// is also checked here because it can identify an outdated Mac before a
    /// connection attempt is made.
    let hasGateWarning: Bool

    private var showsWarning: Bool {
        Self.warningVisible(
            hasGateWarning: hasGateWarning,
            hasOutdatedListAuth: MobileMacListAuthState.shared.entriesByDeviceID.values
                .contains(where: \.isOutdated)
        )
    }

    static func warningVisible(hasGateWarning: Bool, hasOutdatedListAuth: Bool) -> Bool {
        hasGateWarning || hasOutdatedListAuth
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "desktopcomputer")
            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                    .background(.background, in: Circle().inset(by: -1))
                    .offset(x: 5, y: -5)
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
