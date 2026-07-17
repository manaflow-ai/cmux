#if os(iOS) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell
import Foundation
import SwiftUI

/// Deterministic host for accessibility UI tests. It presents the production
/// composer as a real sheet, including its iPad presentation behavior.
public struct TaskComposerAccessibilityPreviewView: View {
    @State private var isPresented = false
    @State private var draftWasPersistedAtSubmit: Bool?
    @State private var submittedMacDeviceID: String?
    @State private var submittedSpec: MobileWorkspaceCreateSpec?
    @State private var selectedDirectory: String?
    private let store: CMUXMobileShellStore
    private let returnsSubmissionFailure: Bool
    private let presentsTemplateForm: Bool
    private let presentsDirectoryPicker: Bool
    private let holdsSubmissionInPreparation: Bool

    /// Creates the preview with isolated, in-memory task state so repeated UI
    /// tests cannot inherit production templates, selections, or drafts. Set
    /// `CMUX_UITEST_TASK_COMPOSER_FAILURE=1` to exercise failure recovery, or
    /// `CMUX_UITEST_TASK_TEMPLATE_FORM_PREVIEW=1` to present the production
    /// add-template form directly. Set
    /// `CMUX_UITEST_TASK_DIRECTORY_PICKER_PREVIEW=1` to present the production
    /// directory picker with deterministic filesystem results.
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
        self.presentsDirectoryPicker = ProcessInfo.processInfo.environment[
            "CMUX_UITEST_TASK_DIRECTORY_PICKER_PREVIEW"
        ] == "1"
        self.holdsSubmissionInPreparation = ProcessInfo.processInfo.environment[
            "CMUX_UITEST_TASK_COMPOSER_HOLD_PREPARATION"
        ] == "1"
    }

    /// Presents the requested production task-composer surface over an otherwise empty host.
    public var body: some View {
        Color.clear
            .onAppear { isPresented = true }
            .overlay {
                if let submittedMacDeviceID, let submittedSpec {
                    TaskComposerSubmissionProbe(
                        macDeviceID: submittedMacDeviceID,
                        spec: submittedSpec
                    )
                }
                if let selectedDirectory {
                    Text(verbatim: selectedDirectory)
                        .accessibilityIdentifier("MobileTaskComposerSelectedDirectory")
                }
            }
            .sheet(isPresented: $isPresented) {
                if presentsTemplateForm {
                    TaskTemplateFormView(template: nil, onSave: { _ in })
                } else if presentsDirectoryPicker {
                    TaskComposerDirectoryPickerView(
                        candidates: [],
                        selectedPath: selectedDirectory ?? "~",
                        select: { selectedDirectory = $0 },
                        searchMac: Self.searchPreviewDirectories,
                        listMac: Self.listPreviewDirectories
                    )
                } else {
                    TaskComposerSheet(
                        store: store,
                        availableMachines: [Self.previewMac, Self.backupPreviewMac],
                        submitTaskComposer: { macDeviceID, spec, willStartCreate in
                            submittedMacDeviceID = macDeviceID
                            submittedSpec = spec
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

    private static let backupPreviewMac = MobilePairedMac(
        macDeviceID: "task-composer-backup-preview-mac",
        displayName: "Backup Preview Mac",
        routes: [],
        createdAt: Date(timeIntervalSince1970: 1),
        lastSeenAt: Date(timeIntervalSince1970: 1),
        isActive: true,
        stackUserID: nil
    )

    private static func searchPreviewDirectories(
        _ query: String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure> {
        let paths = [
            "/Users/ui/mobile-root",
            "/Users/ui/mobile-root/Sources",
            "/Users/ui/mobile-root-archive",
        ]
        let matches = paths.filter { $0.localizedCaseInsensitiveContains(query) }
        return .success(MobileTaskDirectorySearchResponse(
            directories: matches,
            searchScope: .allIndexedVolumes,
            gatheringComplete: true,
            filesystemComplete: false,
            truncated: false,
            indexedMatchCount: matches.count
        ))
    }

    private static func listPreviewDirectories(
        _ requestedPath: String,
        _ offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        let currentPath: String
        let parentPath: String?
        let specs: [(String, String, Bool, Bool, Bool, Bool)]
        switch requestedPath {
        case "~", "/Users/ui":
            currentPath = "/Users/ui"
            parentPath = "/Users"
            specs = [
                (".hidden", "/Users/ui/.hidden", true, false, false, true),
                ("Projects.app", "/Users/ui/Projects.app", false, true, false, true),
                ("mobile-link", "/Users/ui/mobile-link", false, false, true, true),
                ("mobile-root", "/Users/ui/mobile-root", false, false, false, true),
            ]
        case "/":
            currentPath = "/"
            parentPath = nil
            specs = [
                ("Users", "/Users", false, false, false, true),
                ("Volumes", "/Volumes", false, false, false, true),
            ]
        case "/Users/ui/mobile-root":
            currentPath = requestedPath
            parentPath = "/Users/ui"
            specs = [
                ("Sources", "/Users/ui/mobile-root/Sources", false, false, false, true),
            ]
        default:
            currentPath = requestedPath
            parentPath = URL(fileURLWithPath: requestedPath).deletingLastPathComponent().path
            specs = []
        }

        let entries = specs.compactMap { spec in
            MobileTaskDirectoryListEntry(
                name: spec.0,
                path: spec.1,
                isHidden: spec.2,
                isPackage: spec.3,
                isSymbolicLink: spec.4,
                isReadable: spec.5
            )
        }
        guard let response = MobileTaskDirectoryListResponse(
            currentPath: currentPath,
            parentPath: parentPath,
            entries: Array(entries.dropFirst(offset)),
            offset: offset,
            limit: 50,
            totalCount: entries.count,
            nextOffset: nil
        ) else {
            return .failure(.rejected)
        }
        return .success(response)
    }
}

private struct TaskComposerSubmissionProbe: View {
    let macDeviceID: String
    let spec: MobileWorkspaceCreateSpec

    var body: some View {
        VStack {
            Text(verbatim: macDeviceID)
                .accessibilityIdentifier("MobileTaskComposerSubmittedMacDeviceID")
            Text(verbatim: spec.workingDirectory ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedWorkingDirectory")
            Text(verbatim: spec.initialCommand ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedInitialCommand")
            Text(verbatim: spec.initialEnv?["CMUX_TASK_PROMPT"] ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedPrompt")
            Text(verbatim: spec.operationID?.uuidString ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedOperationID")
        }
    }
}

#endif
