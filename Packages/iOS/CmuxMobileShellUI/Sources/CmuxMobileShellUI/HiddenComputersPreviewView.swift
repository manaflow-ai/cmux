#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import SwiftUI

/// DEBUG fixture list for the Hidden Computers rows
/// (`CMUX_UITEST_HIDDEN_COMPUTERS_PREVIEW=1`), so UI tests can exercise the
/// rows' swipe actions without sign-in or Mac pairing.
///
/// The closures mirror production semantics exactly: a Forget swipe tap only
/// presents the row's confirmation dialog (no synchronous model mutation —
/// the regression surface for the destructive-role swipe crash), the dialog's
/// confirm removes the row, and Unhide removes it immediately.
struct HiddenComputersPreviewView: View {
    @State private var computers: [MobileHiddenComputer] = [
        MobileHiddenComputer(
            id: "preview-mac-1",
            macDeviceID: "preview-mac-1",
            instanceTag: nil,
            displayName: "Preview Mac",
            customColor: nil,
            customIcon: nil
        ),
        MobileHiddenComputer(
            id: "preview-mac-2",
            macDeviceID: "preview-mac-2",
            instanceTag: nil,
            displayName: "Studio Mac",
            customColor: nil,
            customIcon: nil
        ),
    ]

    var body: some View {
        NavigationStack {
            List {
                HiddenComputersSection(
                    computers: computers,
                    unhide: { computer in remove(computer.id) },
                    forget: { computer in remove(computer.id) }
                )
            }
            .navigationTitle(HiddenComputersCopy.title)
        }
    }

    private func remove(_ id: String) {
        computers.removeAll { $0.id == id }
    }
}
#endif
