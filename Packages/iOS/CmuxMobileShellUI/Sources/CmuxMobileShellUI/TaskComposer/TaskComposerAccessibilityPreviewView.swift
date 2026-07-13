#if os(iOS) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileShell
import Foundation
import SwiftUI

/// Deterministic host for accessibility UI tests. It presents the production
/// composer as a real sheet, including its iPad presentation behavior.
public struct TaskComposerAccessibilityPreviewView: View {
    @State private var isPresented = false
    @State private var draftWasPersistedAtSubmit: Bool?
    private let store: CMUXMobileShellStore
    private let returnsSubmissionFailure: Bool
    private let presentsTemplateForm: Bool
    private let holdsSubmissionInPreparation: Bool

    /// Creates the preview with isolated, in-memory task state so repeated UI
    /// tests cannot inherit production templates, selections, or drafts. Set
    /// `CMUX_UITEST_TASK_COMPOSER_FAILURE=1` to exercise failure recovery, or
    /// `CMUX_UITEST_TASK_TEMPLATE_FORM_PREVIEW=1` to present the production
    /// add-template form directly.
    public init() {
        self.store = CMUXMobileShellStore(
            isSignedIn: true,
            taskTemplateStore: TaskComposerAccessibilityTemplateStore()
        )
        self.returnsSubmissionFailure = ProcessInfo.processInfo.environment[
            "CMUX_UITEST_TASK_COMPOSER_FAILURE"
        ] == "1"
        self.presentsTemplateForm = ProcessInfo.processInfo.environment[
            "CMUX_UITEST_TASK_TEMPLATE_FORM_PREVIEW"
        ] == "1"
        self.holdsSubmissionInPreparation = ProcessInfo.processInfo.environment[
            "CMUX_UITEST_TASK_COMPOSER_HOLD_PREPARATION"
        ] == "1"
    }

    /// Presents the requested production task-composer surface over an otherwise empty host.
    public var body: some View {
        Color.clear
            .onAppear { isPresented = true }
            .sheet(isPresented: $isPresented) {
                if presentsTemplateForm {
                    TaskTemplateFormView(template: nil, onSave: { _ in })
                } else {
                    TaskComposerSheet(
                        store: store,
                        availableMachines: [Self.previewMac],
                        submitTaskComposer: { _, _, willStartCreate in
                            draftWasPersistedAtSubmit = store.taskTemplateStore?.composerDraft() != nil
                            if holdsSubmissionInPreparation {
                                do {
                                    try await Task.sleep(for: .seconds(30))
                                } catch {
                                    return .failure(.notConnected(hostDisplayName: "Preview Mac"))
                                }
                            }
                            willStartCreate()
                            if returnsSubmissionFailure {
                                return .failure(.invalidWorkingDirectory(hostDisplayName: "Preview Mac"))
                            }
                            return .success(())
                        }
                    )
                    .overlay(alignment: .top) {
                        if let draftWasPersistedAtSubmit {
                            Text(draftWasPersistedAtSubmit ? "persisted" : "missing")
                                .accessibilityIdentifier("MobileTaskComposerSubmissionDraftState")
                        }
                    }
                }
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
