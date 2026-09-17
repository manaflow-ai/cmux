internal import SwiftUI

struct BackendOnlyHostRootView: View {
    let model: BackendOnlyHostModel

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section(
                    backendOnlyLocalizedString(
                        "backendOnly.sidebar.workspaces",
                        defaultValue: "Workspaces"
                    )
                ) {
                    ForEach(model.workspaces, id: \.uuid.rawValue) { workspace in
                        Text(
                            workspace.name.isEmpty
                                ? backendOnlyLocalizedString(
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
                        backendOnlyLocalizedString(
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
            backendOnlyLocalizedString(
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
            backendOnlyLocalizedString(
                "backendOnly.status.connecting",
                defaultValue: "Connecting to terminal backend…"
            )
        case .ready where model.workspaces.isEmpty:
            backendOnlyLocalizedString(
                "backendOnly.status.empty",
                defaultValue: "Create a workspace to start a persistent terminal."
            )
        case .ready:
            backendOnlyLocalizedString(
                "backendOnly.terminal.unavailable",
                defaultValue: "Terminal presentation unavailable"
            )
        case .unavailable:
            backendOnlyLocalizedString(
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
