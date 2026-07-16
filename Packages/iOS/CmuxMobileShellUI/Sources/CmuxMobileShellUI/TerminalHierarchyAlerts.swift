import CmuxMobileSupport
import SwiftUI

extension View {
    func terminalHierarchyResultUnknownRefreshedAlert(
        isPresented: Binding<Bool>
    ) -> some View {
        alert(
            L10n.string(
                "mobile.terminal.hierarchy.resultUnknownRefreshedTitle",
                defaultValue: "Terminal State Refreshed"
            ),
            isPresented: isPresented
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "mobile.terminal.hierarchy.resultUnknownRefreshedMessage",
                    defaultValue: "Latest terminal state loaded. Verify the change."
                )
            )
        }
    }

    func terminalHierarchyCloseUnavailableAlert(
        isPresented: Binding<Bool>
    ) -> some View {
        alert(
            L10n.string(
                "mobile.terminal.hierarchy.closeUnavailableTitle",
                defaultValue: "Terminal Close Unavailable"
            ),
            isPresented: isPresented
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "mobile.terminal.hierarchy.closeUnavailableMessage",
                    defaultValue: "The terminal list changed or another terminal action started. Review the latest state before trying again."
                )
            )
        }
    }

    func terminalHierarchyMoveUnavailableAlert(
        isPresented: Binding<Bool>
    ) -> some View {
        alert(
            L10n.string(
                "mobile.terminal.hierarchy.moveUnavailableTitle",
                defaultValue: "Terminal Move Unavailable"
            ),
            isPresented: isPresented
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
                .accessibilityIdentifier("MobileTerminalHierarchyMoveUnavailableOK")
        } message: {
            Text(
                L10n.string(
                    "mobile.terminal.hierarchy.moveUnavailableMessage",
                    defaultValue: "Another terminal change started first. Wait for it to finish, then try moving this terminal again."
                )
            )
            .accessibilityIdentifier("MobileTerminalHierarchyMoveUnavailableMessage")
        }
    }
}
