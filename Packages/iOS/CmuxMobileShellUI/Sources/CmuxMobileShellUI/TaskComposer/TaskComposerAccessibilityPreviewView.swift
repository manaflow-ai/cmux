#if os(iOS) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileShell
import SwiftUI

/// Deterministic host for accessibility UI tests. It presents the production
/// composer as a real sheet, including its iPad presentation behavior.
public struct TaskComposerAccessibilityPreviewView: View {
    @State private var isPresented = false
    private let store: CMUXMobileShellStore

    /// Creates the preview with the production shell store whose template
    /// persistence and submission state the sheet exercises.
    ///
    /// - Parameter store: The shell store supplied by the app's DEBUG root.
    public init(store: CMUXMobileShellStore) {
        self.store = store
    }

    /// Presents the production task composer over an otherwise empty host.
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
