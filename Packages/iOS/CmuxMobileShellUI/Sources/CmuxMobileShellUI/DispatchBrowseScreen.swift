import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// One level of the Mac's directory tree. Every subdirectory is listed (dot
/// folders behind the Show Hidden toggle), so any path on the Mac is reachable
/// by descending. macOS privacy denials render as an inline notice with the
/// fix, and the level stays navigable.
struct DispatchBrowseScreen: View {
    let path: String
    @Bindable var picker: DispatchProjectPickerModel
    let composer: DispatchComposerModel
    let select: (String) -> Void
    let browse: (String) -> Void

    private enum LevelState {
        case loading
        case loaded(DispatchFSList)
        case failed(DispatchLaunchFailure)
    }

    @State private var level: LevelState = .loading

    private var folderName: String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? "/" : component
    }

    var body: some View {
        Group {
            switch level {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(failure):
                ContentUnavailableView {
                    Label(
                        L10n.string("mobile.dispatch.browse.failed", defaultValue: "Couldn't open this folder"),
                        systemImage: "folder.badge.questionmark"
                    )
                } description: {
                    Text(failure.displayReason(agentName: nil))
                } actions: {
                    Button(L10n.string("mobile.dispatch.retry", defaultValue: "Retry")) {
                        level = .loading
                        Task { await load() }
                    }
                }
            case let .loaded(list):
                levelList(list)
            }
        }
        .navigationTitle(folderName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: $picker.includeHidden) {
                        Label(
                            L10n.string("mobile.dispatch.picker.showHidden", defaultValue: "Show Hidden Folders"),
                            systemImage: "eye"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: picker.includeHidden) {
            await load()
        }
        .accessibilityIdentifier("MobileDispatchBrowse")
    }

    private func load() async {
        switch await picker.loadLevel(path: path) {
        case let .success(list):
            level = .loaded(list)
        case let .failure(failure):
            level = .failed(failure)
        }
    }

    private func levelList(_ list: DispatchFSList) -> some View {
        List {
            Section {
                Button {
                    select(list.path)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string(
                                "mobile.dispatch.browse.useFolder",
                                defaultValue: "Use This Folder"
                            ))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            Text(composer.displayPath(list.path))
                                .font(DispatchStyle.monoCaptionFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("MobileDispatchUseFolder")
            }

            if let notice = list.notice {
                Section {
                    DispatchInlineNotice(
                        icon: "lock",
                        text: noticeText(notice),
                        actionTitle: L10n.string("mobile.dispatch.retry", defaultValue: "Retry"),
                        action: {
                            level = .loading
                            Task { await load() }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(Color.clear)
                }
            }

            if !list.entries.isEmpty {
                Section {
                    ForEach(list.entries) { directory in
                        DispatchDirectoryRow(
                            name: directory.name,
                            detail: composer.displayPath(directory.path),
                            isGit: directory.git,
                            isSelected: composer.directoryPath == directory.path,
                            primaryAction: { browse(directory.path) },
                            browseAction: nil
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                select(directory.path)
                            } label: {
                                Label(
                                    L10n.string("mobile.dispatch.browse.select", defaultValue: "Select"),
                                    systemImage: "checkmark.circle"
                                )
                            }
                            .tint(.accentColor)
                        }
                    }
                } footer: {
                    if list.truncated {
                        Text(L10n.string(
                            "mobile.dispatch.browse.truncated",
                            defaultValue: "This folder has more entries than shown."
                        ))
                    }
                }
            } else if list.notice == nil {
                Section {
                    Text(L10n.string("mobile.dispatch.browse.empty", defaultValue: "No subfolders."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func noticeText(_ notice: DispatchFSNotice) -> String {
        if notice.isPermissionDenied {
            return String(format: L10n.string(
                "mobile.dispatch.browse.permissionDenied.format",
                defaultValue: "macOS blocked cmux from reading “%@”. On the Mac, allow cmux under System Settings › Privacy & Security › Files and Folders, then retry."
            ), folderName)
        }
        return notice.message
    }
}
