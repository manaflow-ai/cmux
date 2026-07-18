public import SwiftUI

public struct TerminalBackendHostApplication: App {
    @StateObject private var model: BackendOnlyHostModel

    public init() {
        _model = StateObject(wrappedValue: BackendOnlyHostModel())
    }

    public var body: some Scene {
        Window(
            BackendOnlyLocalization.string(
                "backendOnly.window.title",
                defaultValue: "cmux Backend"
            ),
            id: "backend-only-main"
        ) {
            BackendOnlyHostRootView(model: model)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { model.start() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 720)
    }
}

private struct BackendOnlyHostRootView: View {
    @ObservedObject var model: BackendOnlyHostModel

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section(
                    BackendOnlyLocalization.string(
                        "backendOnly.sidebar.workspaces",
                        defaultValue: "Workspaces"
                    )
                ) {
                    ForEach(model.workspaces, id: \.uuid.rawValue) { workspace in
                        Text(
                            workspace.name.isEmpty
                                ? BackendOnlyLocalization.string(
                                    "backendOnly.workspace.fallback",
                                    defaultValue: "Workspace"
                                )
                                : workspace.name
                        )
                        .tag(workspace.uuid.rawValue)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: model.createWorkspace) {
                    Label(
                        BackendOnlyLocalization.string(
                            "backendOnly.action.newWorkspace",
                            defaultValue: "New Workspace"
                        ),
                        systemImage: "plus"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
                .disabled(model.phase != .ready)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detail
        }
        .navigationTitle(
            BackendOnlyLocalization.string(
                "backendOnly.window.title",
                defaultValue: "cmux Backend"
            )
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let runtime = model.activeRuntime {
            BackendOnlyTerminalView(runtime: runtime)
                .id(ObjectIdentifier(runtime))
        } else {
            ContentUnavailableView {
                Text(statusText)
            }
        }
    }

    private var statusText: String {
        switch model.phase {
        case .connecting:
            BackendOnlyLocalization.string(
                "backendOnly.status.connecting",
                defaultValue: "Connecting to terminal backend…"
            )
        case .ready where model.workspaces.isEmpty:
            BackendOnlyLocalization.string(
                "backendOnly.status.empty",
                defaultValue: "Create a workspace to start a persistent terminal."
            )
        case .ready:
            BackendOnlyLocalization.string(
                "backendOnly.terminal.unavailable",
                defaultValue: "Terminal presentation unavailable"
            )
        case .unavailable:
            BackendOnlyLocalization.string(
                "backendOnly.status.unavailable",
                defaultValue: "Terminal backend unavailable"
            )
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedWorkspaceID },
            set: { model.selectWorkspace($0) }
        )
    }
}
