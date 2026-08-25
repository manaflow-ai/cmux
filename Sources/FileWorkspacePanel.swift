import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class FileWorkspaceModel {
    private(set) var previewPanel: FilePreviewPanel?
    private var previewPanelsByPath: [String: FilePreviewPanel] = [:]
    private var remoteFileOpenRequestID: UUID?

    func openFile(workspaceID: UUID, filePath: String) {
        if let existing = previewPanelsByPath[filePath] {
            previewPanel = existing
            return
        }

        let preview = FilePreviewPanel(workspaceId: workspaceID, filePath: filePath)
        previewPanelsByPath[filePath] = preview
        previewPanel = preview
    }

    func beginRemoteFileOpenRequest() -> UUID {
        let requestID = UUID()
        remoteFileOpenRequestID = requestID
        return requestID
    }

    @discardableResult
    func completeRemoteFileOpenRequest(
        _ requestID: UUID,
        workspaceID: UUID,
        filePath: String
    ) -> Bool {
        guard remoteFileOpenRequestID == requestID else { return false }
        remoteFileOpenRequestID = nil
        openFile(workspaceID: workspaceID, filePath: filePath)
        return true
    }

    @discardableResult
    func failRemoteFileOpenRequest(_ requestID: UUID) -> Bool {
        guard remoteFileOpenRequestID == requestID else { return false }
        remoteFileOpenRequestID = nil
        return true
    }

    func cancelRemoteFileOpenRequest() {
        remoteFileOpenRequestID = nil
    }

    func close() {
        cancelRemoteFileOpenRequest()
        for preview in previewPanelsByPath.values {
            preview.close()
        }
        previewPanelsByPath.removeAll()
        previewPanel = nil
    }

    func ownsFocus(_ responder: NSResponder, in window: NSWindow) -> Bool {
        previewPanel?.ownedFocusIntent(for: responder, in: window) != nil
    }
}

struct FileWorkspacePanelView: View {
    @Bindable var model: FileWorkspaceModel
    @ObservedObject var explorerStore: FileExplorerStore
    @ObservedObject var explorerState: FileExplorerState
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onOpenFile: (String) -> Void
    let onRequestPanelFocus: () -> Void
    let onExplorerContainerChange: (FileExplorerContainerView?) -> Void

    var body: some View {
        HSplitView {
            editor
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            FileExplorerPanelView(
                store: explorerStore,
                state: explorerState,
                onOpenFilePreview: onOpenFile,
                presentation: .workspace,
                placement: .pane,
                onFocus: onRequestPanelFocus,
                onContainerChange: onExplorerContainerChange
            )
            .frame(minWidth: 240, idealWidth: 320, maxWidth: 520, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let previewPanel = model.previewPanel {
            FilePreviewPanelView(
                panel: previewPanel,
                isFocused: isFocused,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                appearance: appearance,
                onRequestPanelFocus: onRequestPanelFocus
            )
            .id(previewPanel.id)
        } else {
            ContentUnavailableView {
                Label(
                    String(localized: "fileWorkspace.empty.title", defaultValue: "Select a file"),
                    systemImage: "doc.text.magnifyingglass"
                )
            } description: {
                Text(
                    String(
                        localized: "fileWorkspace.empty.description",
                        defaultValue: "Choose a file from the explorer to open it here."
                    )
                )
            }
            .foregroundStyle(Color(nsColor: appearance.foregroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.contentBackgroundColor))
        }
    }
}
