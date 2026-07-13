#if os(iOS) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileShell
import SwiftUI

/// Deterministic host for accessibility UI tests. It presents the production
/// composer as a real sheet, including its iPad presentation behavior.
public struct TaskComposerAccessibilityPreviewView: View {
    @State private var isPresented = false
    private let store: CMUXMobileShellStore

    public init(store: CMUXMobileShellStore) {
        self.store = store
    }

    public var body: some View {
        Color.clear
            .onAppear { isPresented = true }
            .sheet(isPresented: $isPresented) {
                TaskComposerSheet(
                    store: store,
                    availableMachines: [Self.previewMac],
                    submitTaskComposer: { _, _ in .success(()) }
                )
            }
    }

    private static let previewMac = MobilePairedMac(
        macDeviceID: "task-composer-preview-mac",
        displayName: "Preview Mac",
        routes: [],
        createdAt: Date(timeIntervalSince1970: 0),
        lastSeenAt: Date(timeIntervalSince1970: 0),
        isActive: true,
        stackUserID: nil
    )
}
#endif
