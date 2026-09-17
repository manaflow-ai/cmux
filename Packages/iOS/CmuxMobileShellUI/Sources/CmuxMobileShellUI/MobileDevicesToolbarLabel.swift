#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The shared Devices toolbar glyph. The warning is intentionally a small
/// standard SF Symbol overlay so the action remains recognizable while making
/// a blocked Mac discoverable before the user opens the Computers sheet.
struct MobileDevicesToolbarLabel: View {
    /// Macs whose last authenticated attempt was rejected by the version gate.
    let gateWarningPairingIDs: Set<String>
    /// The physical Macs represented by the Computers sheet opened by this
    /// button. List-auth state is filtered to this set so an unrelated stale
    /// entry cannot light the toolbar badge.
    let computerPairingIDs: Set<String>

    private var showsWarning: Bool {
        let listAuth = MobileMacListAuthState.shared
        let hasOutdatedListAuth = computerPairingIDs.contains { pairingID in
            listAuth.compatibilityEntry(pairingID: pairingID).isOutdated
        }
        return Self.warningVisible(
            hasGateWarning: !gateWarningPairingIDs.isDisjoint(with: computerPairingIDs),
            hasOutdatedListAuth: hasOutdatedListAuth,
            hasComputers: !computerPairingIDs.isEmpty
        )
    }

    init(
        gateWarningPairingIDs: Set<String> = [],
        computerPairingIDs: Set<String> = []
    ) {
        self.gateWarningPairingIDs = gateWarningPairingIDs
        self.computerPairingIDs = computerPairingIDs
    }

    static func warningVisible(
        hasGateWarning: Bool,
        hasOutdatedListAuth: Bool,
        hasComputers: Bool = true
    ) -> Bool {
        hasComputers && (hasGateWarning || hasOutdatedListAuth)
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
