#if os(iOS) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI
import UIKit

/// Deterministic host for accessibility UI tests. It presents the production
/// composer through its real presenter, including iPad keyboard behavior.
public struct TaskComposerAccessibilityPreviewView: View {
    @State private var isPresented = false
    @State private var draftWasPersistedAtSubmit: Bool?
    @State private var submittedMacDeviceID: String?
    @State private var submittedSpec: MobileWorkspaceCreateSpec?
    @State private var submissionAttempts: [TaskComposerSubmissionAttempt] = []
    @State private var selectedDirectory: String?
    @State private var stagedPreviewAttachments: [TaskComposerAttachment] = []
    private let store: CMUXMobileShellStore
    private let returnsSubmissionFailure: Bool
    private let failsFirstSubmission: Bool
    private let presentsTemplateForm: Bool
    private let presentsDirectoryPicker: Bool
    private let presentsDirectoryPermissionFailure: Bool
    private let presentsDirectoryScrollStress: Bool
    private let holdsSubmissionInPreparation: Bool
    private let advertisesTaskAttachments: Bool
    private let startsWithStagedAttachments: Bool
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
    /// first page-2 request fail and its exact retry succeed. Set
    /// `CMUX_UITEST_TASK_COMPOSER_ATTACHMENTS=1` to advertise the attachment
    /// capability and render the fully populated composer row. Set
    /// `CMUX_UITEST_TASK_COMPOSER_STAGED_ATTACHMENTS=1` to start with one image
    /// and one document whose exact app-owned bytes can be previewed.
    public init() {
        let environment = ProcessInfo.processInfo.environment
        let presentsDirectoryPaginationRecovery = environment[
            "CMUX_UITEST_TASK_DIRECTORY_PAGINATION_RECOVERY_PREVIEW"
        ] == "1"
        let presentsDirectoryScrollStress = environment[
            "CMUX_UITEST_TASK_DIRECTORY_SCROLL_STRESS"
        ] == "1"
        let presentsDirectoryPermissionFailure = environment[
            "CMUX_UITEST_TASK_DIRECTORY_PERMISSION_FAILURE_PREVIEW"
        ] == "1"
        let presentsOpenDirectory = environment[
            "CMUX_UITEST_TASK_COMPOSER_OPEN_DIRECTORY_PREVIEW"
        ] == "1"
        let templateStore = TaskComposerAccessibilityTemplateStore()
        if environment["CMUX_UITEST_TASK_COMPOSER_LONG_PROMPT"] == "1" {
            templateStore.setComposerDraft(MobileTaskComposerDraft(
                prompt: Self.longPrompt,
                templateID: templateStore.listTemplates().first?.id,
                macDeviceID: Self.previewMac.macDeviceID,
                macInstanceTag: Self.previewMac.instanceTag,
                directory: "~",
                didEditDirectory: false
            ))
        }
        if environment["CMUX_UITEST_TASK_COMPOSER_RESTORED_MODEL_DRAFT"] == "1" {
            templateStore.setComposerDraft(MobileTaskComposerDraft(
                prompt: "Retry the persisted model",
                modelID: "persisted-agent-model",
                templateID: templateStore.listTemplates().first?.id,
                macDeviceID: Self.previewMac.macDeviceID,
                macInstanceTag: Self.previewMac.instanceTag,
                directory: "~",
                didEditDirectory: false,
                operationID: UUID(uuidString: "0D9A7F2E-0B69-49C7-A725-F6F72517C584")
            ))
        }
        if presentsOpenDirectory {
            templateStore.setLastDirectory(
                "/Users/ui/previous-task",
                macDeviceID: Self.previewMac.macDeviceID
            )
        }
        let catalogData = environment["CMUX_UITEST_TASK_MODEL_CATALOG_JSON"]?
            .data(using: .utf8)
        let catalogClient = MobileTaskModelCatalogClient(
            endpoint: URL(string: "https://task-model-catalog.invalid")!
        ) { _ in
            guard let catalogData else {
                throw URLError(.resourceUnavailable)
            }
            return catalogData
        }
        self.store = CMUXMobileShellStore(
            isSignedIn: true,
            workspaces: presentsOpenDirectory ? [Self.openDirectoryWorkspace] : [],
            taskTemplateStore: templateStore,
            taskModelCatalogClient: catalogClient
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
        ] == "1" || presentsDirectoryPaginationRecovery || presentsDirectoryPermissionFailure
        self.presentsDirectoryPermissionFailure = presentsDirectoryPermissionFailure
        self.presentsDirectoryScrollStress = presentsDirectoryScrollStress
        self.holdsSubmissionInPreparation = environment[
            "CMUX_UITEST_TASK_COMPOSER_HOLD_PREPARATION"
        ] == "1"
        let startsWithStagedAttachments = environment[
            "CMUX_UITEST_TASK_COMPOSER_STAGED_ATTACHMENTS"
        ] == "1"
        self.startsWithStagedAttachments = startsWithStagedAttachments
        self.advertisesTaskAttachments = startsWithStagedAttachments || environment[
            "CMUX_UITEST_TASK_COMPOSER_ATTACHMENTS"
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
            .task {
                if startsWithStagedAttachments,
                   stagedPreviewAttachments.isEmpty {
                    stagedPreviewAttachments = await Self.makeStagedPreviewAttachments()
                }
                isPresented = true
            }
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
            .taskComposerPresentation(isPresented: $isPresented) {
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
                        availableMachines: [
                            Self.previewMac,
                            Self.stablePreviewMac,
                            Self.backupPreviewMac,
                        ],
                        availableWorkspaceGroups: [Self.previewWorkspaceGroup],
                        taskAttachmentsCapabilityOverride: advertisesTaskAttachments ? true : nil,
                        initialAttachments: stagedPreviewAttachments,
                        submitTaskComposer: { macDeviceID, _, spec, willStartCreate in
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
                        searchTaskDirectories: { _, _, query in
                            await Self.searchPreviewDirectories(query)
                        },
                        listTaskDirectories: { _, _, path, offset in
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
        stackUserID: nil,
        instanceTag: "nightly"
    )

    private static let previewWorkspaceGroup = MobileWorkspaceGroupPreview(
        id: "task-composer-preview-group",
        macDeviceID: previewMac.macDeviceID,
        macInstanceTag: previewMac.instanceTag,
        name: "Focus work",
        anchorWorkspaceID: "task-composer-preview-group-anchor"
    )

    private static let longPrompt = (1...80)
        .map { "Prompt line \($0): keep the editor scroll gesture inside the text canvas." }
        .joined(separator: "\n")

    private static let stablePreviewMac = MobilePairedMac(
        macDeviceID: "task-composer-preview-mac",
        displayName: "Preview Mac",
        routes: [],
        createdAt: Date(timeIntervalSince1970: 0),
        lastSeenAt: Date(timeIntervalSince1970: 0),
        isActive: false,
        stackUserID: nil,
        instanceTag: "stable"
    )

    private static let backupPreviewMac = MobilePairedMac(
        macDeviceID: "task-composer-backup-preview-mac",
        displayName: "Backup Preview Mac",
        routes: [],
        createdAt: Date(timeIntervalSince1970: 1),
        lastSeenAt: Date(timeIntervalSince1970: 1),
        isActive: true,
        stackUserID: nil,
        instanceTag: "stable"
    )

    private static let openDirectoryWorkspace = MobileWorkspacePreview(
        id: "workspace-current",
        macDeviceID: previewMac.macDeviceID,
        name: "Current project",
        currentDirectory: "/Users/ui/current-project",
        terminals: []
    )

    @MainActor
    private static func makeStagedPreviewAttachments() async -> [TaskComposerAttachment] {
        guard let imageData = stagedPreviewImageData() else { return [] }
        return await Task.detached(priority: .utility) {
            guard let imageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            let fileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") else {
                return []
            }
            let fileData = Data("Attachment preview fixture\n".utf8)
            let directory = FileManager.default.temporaryDirectory
            let imageURL = directory.appendingPathComponent(
                "cmux-task-preview-photo.png"
            )
            let fileURL = directory.appendingPathComponent(
                "cmux-task-preview-notes.txt"
            )
            do {
                try imageData.write(to: imageURL, options: .atomic)
                try fileData.write(to: fileURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: imageURL)
                try? FileManager.default.removeItem(at: fileURL)
                return []
            }
            return [
                TaskComposerAttachment(
                    id: imageID,
                    kind: .image,
                    displayName: "preview-photo.png",
                    localStagedFileURL: imageURL,
                    byteCount: imageData.count,
                    thumbnailData: imageData
                ),
                TaskComposerAttachment(
                    id: fileID,
                    kind: .file,
                    displayName: "preview-notes.txt",
                    localStagedFileURL: fileURL,
                    byteCount: fileData.count
                ),
            ]
        }.value
    }

    /// Produces a deterministic, high-chroma PNG so UI tests can distinguish
    /// the staged bytes from Quick Look chrome or a blank placeholder.
    @MainActor
    private static func stagedPreviewImageData() -> Data? {
        let cellCount = 8
        let cellSize: CGFloat = 40
        let size = CGSize(
            width: CGFloat(cellCount) * cellSize,
            height: CGFloat(cellCount) * cellSize
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            for row in 0..<cellCount {
                for column in 0..<cellCount {
                    let index = row * cellCount + column
                    UIColor(
                        hue: CGFloat(index) / CGFloat(cellCount * cellCount),
                        saturation: 0.9,
                        brightness: 0.95,
                        alpha: 1
                    ).setFill()
                    UIRectFill(CGRect(
                        x: CGFloat(column) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    ))
                }
            }
        }
    }

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
        if presentsDirectoryPermissionFailure {
            return .failure(.rejected)
        }
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
            Text(verbatim: spec.title ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedTitle")
            Text(verbatim: spec.initialCommand ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedInitialCommand")
            Text(verbatim: spec.initialEnv?["CMUX_TASK_PROMPT"] ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedPrompt")
            Text(verbatim: spec.workspaceGroupID?.rawValue ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedWorkspaceGroupID")
            Text(verbatim: spec.operationID?.uuidString ?? "<nil>")
                .accessibilityIdentifier("MobileTaskComposerSubmittedOperationID")
        }
    }
}

#endif
