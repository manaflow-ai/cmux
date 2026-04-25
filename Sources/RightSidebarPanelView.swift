import AppKit
import SwiftUI

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
enum RightSidebarMode: String, CaseIterable {
    case files
    case sessions

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Sessions")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .sessions: return "bubble.left.and.text.bubble.right"
        }
    }
}

/// Right sidebar root view. Hosts a segmented mode picker plus the active panel.
struct RightSidebarPanelView: View {
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    @ObservedObject var sessionIndexStore: SessionIndexStore
    let onResumeSession: ((SessionEntry) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            contentForMode
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("RightSidebar")
    }

    private var modeBar: some View {
        HStack(spacing: 4) {
            ForEach(RightSidebarMode.allCases, id: \.rawValue) { mode in
                ModeBarButton(
                    mode: mode,
                    isSelected: fileExplorerState.mode == mode
                ) {
                    if fileExplorerState.mode != mode {
                        fileExplorerState.mode = mode
                        if mode == .sessions {
                            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                            if sessionIndexStore.entries.isEmpty {
                                sessionIndexStore.reload()
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(height: 31)
    }

    @ViewBuilder
    private var contentForMode: some View {
        switch fileExplorerState.mode {
        case .files:
            FileExplorerPanelView(store: fileExplorerStore, state: fileExplorerState)
        case .sessions:
            SessionIndexView(store: sessionIndexStore, onResume: onResumeSession)
                .onAppear {
                    sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                }
        }
    }

    private var sessionIndexDirectory: String? {
        fileExplorerStore.rootPath.isEmpty ? nil : fileExplorerStore.rootPath
    }
}

private struct ModeBarButton: View {
    let mode: RightSidebarMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: mode.symbolName)
                    .cmuxFont(size: 11, weight: .medium)
                Text(mode.label)
                    .cmuxFont(size: 11, weight: .medium)
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(mode.label)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.10)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }
}
