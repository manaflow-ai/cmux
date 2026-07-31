import CmuxExtensionKit
import SwiftUI

struct SurfaceStatusSidebarView: View {
    var model: SidebarConnectionModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ExtensionKit renders in a separate remote surface, so use one
            // opaque semantic fill from the first extension-owned frame. This
            // follows macOS appearance without adding material, blur, alpha
            // compositing, animation, or continuous rendering work.
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

            if let snapshot = model.snapshot {
                workspaceList(snapshot)
            } else {
                waitingState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workspaceList(_ snapshot: CmuxSidebarSnapshot) -> some View {
        List {
            if let errorText = model.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.orange.opacity(0.08))
            }

            ForEach(snapshot.workspaces) { workspace in
                Section {
                    if workspace.surfaces.isEmpty {
                        Label(
                            String(localized: "surfaceSidebar.noSurfaces", defaultValue: "No surfaces"),
                            systemImage: "rectangle.on.rectangle.slash"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .listRowInsets(EdgeInsets(top: 4, leading: 32, bottom: 4, trailing: 10))
                    } else {
                        ForEach(workspace.surfaces) { surface in
                            SurfaceStatusRow(
                                surface: surface,
                                lifecycle: model.lifecycle(for: surface.id)
                            ) {
                                Task { @MainActor in
                                    await model.selectSurface(workspaceID: workspace.id, surfaceID: surface.id)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 1, leading: 25, bottom: 1, trailing: 7))
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    WorkspaceHeader(
                        workspace: workspace,
                        isSelected: workspace.id == snapshot.selectedWorkspaceID
                    ) {
                        Task { @MainActor in await model.selectWorkspace(workspace.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private var waitingState: some View {
        // ExtensionKit may mount this view before the initial XPC snapshot.
        // Keep that transient frame visually inert instead of flashing a
        // spinner, "Waiting for CMUX", or a refresh button during app launch.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct WorkspaceHeader: View {
    let workspace: CmuxSidebarWorkspace
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 15)

                Text(stableWorkspaceTitle)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(workspace.surfaces.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityLabel(stableWorkspaceTitle)
    }

    private var stableWorkspaceTitle: String {
        // `workspace.title` may be derived from a process-controlled terminal
        // title, including recent agent output. The public snapshot does not
        // expose title provenance, so use path metadata as the stable identity.
        if let rootPath = workspace.rootPath {
            let rootName = (rootPath as NSString).lastPathComponent
            if !rootName.isEmpty { return rootName }
        }
        if let projectRootPath = workspace.projectRootPath {
            let projectName = (projectRootPath as NSString).lastPathComponent
            if !projectName.isEmpty { return projectName }
        }
        return String(localized: "surfaceSidebar.workspaceFallback", defaultValue: "Workspace")
    }
}

private struct SurfaceStatusRow: View {
    let surface: CmuxSidebarSurface
    let lifecycle: SurfaceAgentLifecycle?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: surfaceIconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(surface.isFocused ? Color.primary : Color.secondary)
                    .frame(width: 16)

                Text(surfaceDisplayTitle)
                    .font(.system(size: 12, weight: surface.isFocused ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                if let lifecycle {
                    let visualState = AgentVisualState(
                        lifecycle: lifecycle,
                        hasUnread: surface.unreadCount > 0
                    )
                    HStack(spacing: 4) {
                        AgentStateIcon(state: visualState, size: 9)
                        Text(lifecycleLabel(lifecycle, visualState: visualState))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(visualState.color)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(visualState.accessibilityLabel)
                    .help(lifecycle.statusMessage ?? visualState.accessibilityLabel)
                }

                if surface.unreadCount > 0 {
                    HStack(spacing: 4) {
                        if lifecycle.map({ AgentVisualState(lifecycle: $0, hasUnread: false) != .blocked }) ?? true {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        Text("\(surface.unreadCount)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(lifecycle?.state == .idle ? Color.green : Color.orange)
                    .accessibilityLabel(
                        String.localizedStringWithFormat(
                            String(localized: "surfaceSidebar.unreadCount", defaultValue: "%lld unread"),
                            Int64(surface.unreadCount)
                        )
                    )
                }
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 25)
            .background {
                if surface.isFocused {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.20))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(surfaceDisplayTitle)
        .accessibilityLabel(surfaceAccessibilityLabel)
    }

    private var surfaceDisplayTitle: String {
        if let lifecycle {
            return agentDisplayName(lifecycle.agentID)
        }
        // Terminal titles are process-controlled and may contain the most recent
        // agent response. They are not a stable sidebar identity, so never expose
        // them as a fallback when lifecycle state has not arrived or was removed.
        switch surface.kind {
        case .terminal:
            return String(localized: "surfaceSidebar.surfaceTerminal", defaultValue: "Terminal")
        case .agentSession:
            return String(localized: "surfaceSidebar.surfaceAgentSession", defaultValue: "Agent session")
        default:
            return surface.title
        }
    }

    private var surfaceAccessibilityLabel: String {
        var parts = [surfaceDisplayTitle]
        if let lifecycle {
            parts.append(AgentVisualState(
                lifecycle: lifecycle,
                hasUnread: surface.unreadCount > 0
            ).accessibilityLabel)
        }
        if surface.unreadCount > 0 {
            parts.append(String.localizedStringWithFormat(
                String(localized: "surfaceSidebar.unreadCount", defaultValue: "%lld unread"),
                Int64(surface.unreadCount)
            ))
        }
        return parts.joined(separator: ", ")
    }

    private func lifecycleLabel(
        _ lifecycle: SurfaceAgentLifecycle,
        visualState: AgentVisualState
    ) -> String {
        visualState.accessibilityLabel
    }

    private func agentDisplayName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "omp": return "OMP"
        case "gemini": return "Gemini"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case "grok": return "Grok"
        default: return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var surfaceIconName: String {
        switch surface.kind {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.richtext"
        case .filePreview: return "doc"
        case .rightSidebarTool: return "sidebar.right"
        case .agentSession: return "bubble.left.and.text.bubble.right"
        case .project: return "folder"
        case .unknown: return "rectangle"
        }
    }
}

private enum AgentVisualState: Int, Comparable {
    case unknown = 0
    case idle = 1
    case working = 2
    case done = 3
    case blocked = 4
    case error = 5
    case rateLimited = 6

    init(lifecycle: SurfaceAgentLifecycle, hasUnread: Bool) {
        if lifecycle.reason == .rateLimit || lifecycle.state == .rateLimited {
            self = .rateLimited
            return
        }
        if lifecycle.reason == .error {
            self = .error
            return
        }
        switch lifecycle.state {
        case .rateLimited: self = .rateLimited
        case .needsInput: self = .blocked
        case .done: self = .done
        case .running: self = .working
        case .idle: self = hasUnread ? .done : .idle
        case .unknown: self = .unknown
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: Color {
        switch self {
        case .rateLimited, .error: return .red
        case .blocked: return .orange
        case .done: return .green
        case .working: return .blue
        case .idle, .unknown: return .secondary
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .error:
            return String(localized: "surfaceSidebar.stateError", defaultValue: "Error")
        case .rateLimited:
            return String(localized: "surfaceSidebar.stateRateLimited", defaultValue: "Rate limit")
        case .blocked:
            return String(localized: "surfaceSidebar.stateBlocked", defaultValue: "Needs input")
        case .done:
            return String(localized: "surfaceSidebar.stateDone", defaultValue: "Done")
        case .working:
            return String(localized: "surfaceSidebar.stateWorking", defaultValue: "Working")
        case .idle:
            return String(localized: "surfaceSidebar.stateIdle", defaultValue: "Idle")
        case .unknown:
            return String(localized: "surfaceSidebar.stateUnknown", defaultValue: "Unknown")
        }
    }
}

private struct AgentStateIcon: View {
    let state: AgentVisualState
    let size: CGFloat

    var body: some View {
        Group {
            if state == .working {
                ProgressView()
                    .controlSize(.mini)
                    .tint(state.color)
                    .scaleEffect(0.65)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: size, weight: .semibold))
            }
        }
        .foregroundStyle(state.color)
        .frame(width: 11, height: 11)
    }

    private var iconName: String {
        switch state {
        case .rateLimited: return "gauge.with.dots.needle.67percent"
        case .error: return "exclamationmark.triangle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "circle.dotted"
        case .idle: return "circle"
        case .unknown: return "circle.dashed"
        }
    }
}
