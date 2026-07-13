#if os(iOS) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileShell
import Foundation
import SwiftUI

/// Deterministic host for accessibility UI tests. It presents the production
/// composer as a real sheet, including its iPad presentation behavior.
public struct TaskComposerAccessibilityPreviewView: View {
    @State private var isPresented = false
    private let store: CMUXMobileShellStore
    private let returnsSubmissionFailure: Bool

    /// Creates the preview with isolated, in-memory task state so repeated UI
    /// tests cannot inherit production templates, selections, or drafts. Set
    /// `CMUX_UITEST_TASK_COMPOSER_FAILURE=1` to exercise failure recovery.
    public init() {
        self.store = CMUXMobileShellStore(
            taskTemplateStore: TaskComposerAccessibilityTemplateStore()
        )
        self.returnsSubmissionFailure = ProcessInfo.processInfo.environment[
            "CMUX_UITEST_TASK_COMPOSER_FAILURE"
        ] == "1"
    }

    /// Presents the production task composer over an otherwise empty host.
    public var body: some View {
        Color.clear
            .onAppear { isPresented = true }
            .sheet(isPresented: $isPresented) {
                TaskComposerSheet(
                    store: store,
                    availableMachines: [Self.previewMac],
                    submitTaskComposer: { _, _ in
                        if returnsSubmissionFailure {
                            return .failure(.invalidWorkingDirectory(hostDisplayName: "Preview Mac"))
                        }
                        return .success(())
                    }
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
