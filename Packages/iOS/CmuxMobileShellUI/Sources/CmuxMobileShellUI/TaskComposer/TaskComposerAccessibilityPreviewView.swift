#if os(iOS) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI

/// Deterministic host for accessibility UI tests. It presents the production
/// composer as a real sheet, including its iPad presentation behavior.
public struct TaskComposerAccessibilityPreviewView: View {
    @State private var isPresented = false
    @State private var draftWasPersistedAtSubmit: Bool?
    @State private var submittedMacDeviceID: String?
    @State private var submittedSpec: MobileWorkspaceCreateSpec?
    @State private var submissionAttempts: [TaskComposerSubmissionAttempt] = []
    @State private var selectedDirectory: String?
    private let store: CMUXMobileShellStore
    private let returnsSubmissionFailure: Bool
    private let failsFirstSubmission: Bool
    private let presentsTemplateForm: Bool
    private let presentsDirectoryPicker: Bool
    private let presentsDirectoryScrollStress: Bool
    private let holdsSubmissionInPreparation: Bool
    @State private var directoryPaginationRecoveryPreview: TaskComposerDirectoryPaginationRecoveryPreview?

    /// Creates the preview with isolated, in-memory task state so repeated UI
    /// tests cannot inherit production templates, selections, or drafts. Set
    /// `CMUX_UITEST_TASK_COMPOSER_FAILURE=1` to exercise a persistent failure,
    /// `CMUX_UITEST_TASK_COMPOSER_FAIL_ONCE=1` to exercise a successful retry,
    /// or `CMUX_UITEST_TASK_TEMPLATE_FORM_PREVIEW=1` to present the production
    /// add-template form directly. Set
    /// `CMUX_UITEST_TASK_DIRECTORY_PICKER_PREVIEW=1` to present the production
    /// directory picker with deterministic filesystem results. Set
    /// `CMUX_UITEST_TASK_DIRECTORY_PAGINATION_RECOVERY_PREVIEW=1` to make the
    /// first page-2 request fail and its exact retry succeed.
    public init() {
        let environment = ProcessInfo.processInfo.environment
        let presentsDirectoryPaginationRecovery = environment[
            "CMUX_UITEST_TASK_DIRECTORY_PAGINATION_RECOVERY_PREVIEW"
        ] == "1"
        let presentsDirectoryScrollStress = environment[
            "CMUX_UITEST_TASK_DIRECTORY_SCROLL_STRESS"
        ] == "1"
        self.store = CMUXMobileShellStore(
            isSignedIn: true,
            taskTemplateStore: TaskComposerAccessibilityTemplateStore()
        )
        self.returnsSubmissionFailure = environment[
            "CMUX_UITEST_TASK_COMPOSER_FAILURE"
        ] == "1"
        self.failsFirstSubmission = environment[
            "CMUX_UITEST_TASK_COMPOSER_FAIL_ONCE"
        ] == "1"
        self.presentsTemplateForm = environment[
            "CMUX_UITEST_TASK_TEMPLATE_FORM_PREVIEW"
        ] == "1"
        self.presentsDirectoryPicker = environment[
            "CMUX_UITEST_TASK_DIRECTORY_PICKER_PREVIEW"
        ] == "1" || presentsDirectoryPaginationRecovery
        self.presentsDirectoryScrollStress = presentsDirectoryScrollStress
        self.holdsSubmissionInPreparation = environment[
            "CMUX_UITEST_TASK_COMPOSER_HOLD_PREPARATION"
        ] == "1"
        _directoryPaginationRecoveryPreview = State(
            initialValue: presentsDirectoryPaginationRecovery
                ? TaskComposerDirectoryPaginationRecoveryPreview()
                : nil
        )
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
                if !isPresented {
                    TaskComposerSubmissionHistoryProbe(attempts: submissionAttempts)
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
                        listMac: listDirectoriesForPreview
                    )
                } else {
                    TaskComposerSheet(
                        store: store,
                        availableMachines: [Self.previewMac, Self.backupPreviewMac],
                        submitTaskComposer: { macDeviceID, spec, willStartCreate in
                            let attemptNumber = submissionAttempts.count + 1
                            submittedMacDeviceID = macDeviceID
                            submittedSpec = spec
                            submissionAttempts.append(TaskComposerSubmissionAttempt(
                                id: attemptNumber,
                                operationID: spec.operationID?.uuidString ?? "<nil>",
                                prompt: spec.initialEnv?["CMUX_TASK_PROMPT"] ?? "<nil>"
                            ))
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
                            if failsFirstSubmission {
                                if attemptNumber == 1 {
                                    return .failure(.invalidWorkingDirectory(hostDisplayName: "Preview Mac"))
                                }
                                do {
                                    try await Task.sleep(for: .seconds(2))
                                } catch {
                                    return .failure(.notConnected(hostDisplayName: "Preview Mac"))
                                }
                            }
                            return .success(())
                        },
                        searchTaskDirectories: { _, query in
                            await Self.searchPreviewDirectories(query)
                        },
                        listTaskDirectories: { _, path, offset in
                            await listDirectoriesForPreview(path, offset)
                        }
                    )
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            if let draftWasPersistedAtSubmit {
                                Text(
                                    draftWasPersistedAtSubmit
                                        ? L10n.string(
                                            "mobile.taskComposer.debug.draftPersisted",
                                            defaultValue: "persisted"
                                        )
                                        : L10n.string(
                                            "mobile.taskComposer.debug.draftMissing",
                                            defaultValue: "missing"
                                        )
                                )
                                    .accessibilityIdentifier("MobileTaskComposerSubmissionDraftState")
                            }
                            TaskComposerSubmissionHistoryProbe(attempts: submissionAttempts)
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

    private func listDirectoriesForPreview(
        _ requestedPath: String,
        _ offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        if presentsDirectoryScrollStress {
            return Self.listScrollStressDirectories(requestedPath, offset)
        }
        if let directoryPaginationRecoveryPreview {
            return await directoryPaginationRecoveryPreview.listDirectories(
                requestedPath,
                offset
            )
        }
        return await Self.listPreviewDirectories(requestedPath, offset)
    }

    private static func listScrollStressDirectories(
        _ requestedPath: String,
        _ offset: Int
    ) -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        guard requestedPath == "~" || requestedPath == "/Users/ui",
              offset == 0 else {
            return .failure(.rejected)
        }
        let entries = (0..<50).compactMap { index in
            let name = String(format: "folder-%02d", index)
            return MobileTaskDirectoryListEntry(
                name: name,
                path: "/Users/ui/\(name)",
                isHidden: false,
                isPackage: false,
                isSymbolicLink: false,
                isReadable: true
            )
        }
        guard entries.count == 50,
              let response = MobileTaskDirectoryListResponse(
                  currentPath: "/Users/ui",
                  parentPath: "/Users",
                  entries: entries,
                  offset: 0,
                  limit: 50,
                  totalCount: entries.count,
                  nextOffset: nil
              ) else {
            return .failure(.rejected)
        }
        return .success(response)
    }
}

private actor TaskComposerDirectoryPaginationRecoveryPreview {
    private struct AppendRequest: Equatable {
        let path: String
        let offset: Int
    }

    private var failedAppendRequest: AppendRequest?

    func listDirectories(
        _ requestedPath: String,
        _ offset: Int
    ) -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        if offset == 0 {
            guard requestedPath == "~" || requestedPath == "/Users/ui" else {
                return .failure(.rejected)
            }
            return Self.page(
                entries: [
                    ("first-page-folder", "/Users/ui/first-page-folder", true),
                    ("unreadable-page-one", "/Users/ui/unreadable-page-one", false),
                ],
                offset: 0,
                nextOffset: 2
            )
        }

        let request = AppendRequest(path: requestedPath, offset: offset)
        let expectedRequest = AppendRequest(path: "/Users/ui", offset: 2)
        guard request == expectedRequest else {
            return .failure(.rejected)
        }
        guard let failedAppendRequest else {
            self.failedAppendRequest = request
            return .failure(.timedOut)
        }
        guard request == failedAppendRequest else {
            return .failure(.rejected)
        }

        return Self.page(
            entries: [
                ("z-second-page-folder", "/Users/ui/z-second-page-folder", true),
            ],
            offset: 2,
            nextOffset: nil
        )
    }

    private static func page(
        entries: [(name: String, path: String, isReadable: Bool)],
        offset: Int,
        nextOffset: Int?
    ) -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure> {
        let directoryEntries = entries.compactMap { entry in
            MobileTaskDirectoryListEntry(
                name: entry.name,
                path: entry.path,
                isHidden: false,
                isPackage: false,
                isSymbolicLink: false,
                isReadable: entry.isReadable
            )
        }
        guard directoryEntries.count == entries.count,
              let response = MobileTaskDirectoryListResponse(
                  currentPath: "/Users/ui",
                  parentPath: "/Users",
                  entries: directoryEntries,
                  offset: offset,
                  limit: 2,
                  totalCount: 3,
                  nextOffset: nextOffset
              ) else {
            return .failure(.rejected)
        }
        return .success(response)
    }
}

private struct TaskComposerSubmissionAttempt: Identifiable {
    let id: Int
    let operationID: String
    let prompt: String
}

private struct TaskComposerSubmissionHistoryProbe: View {
    let attempts: [TaskComposerSubmissionAttempt]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(attempts) { attempt in
                Text(verbatim: attempt.operationID)
                    .accessibilityIdentifier("MobileTaskComposerSubmittedOperationID-\(attempt.id)")
                Text(verbatim: attempt.prompt)
                    .accessibilityIdentifier("MobileTaskComposerSubmittedPrompt-\(attempt.id)")
            }
        }
        .allowsHitTesting(false)
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
