import CmuxWorkspacesKit
import SwiftUI

/// Launch arguments for screenshots: `-design recents|triage|cards` opens a
/// design directly; `-workspace <id>` also pushes that workspace.
@main
struct WorkspacesDemoApp: App {
    @State private var store = WorkspacesStore.sample()
    @State private var design: WorkspacesDesign? = Self.argument("-design").flatMap(WorkspacesDesign.init(rawValue:))

    var body: some Scene {
        WindowGroup {
            DesignPicker(design: $design)
                .fullScreenCover(item: $design) { design in
                    WorkspacesHomeView(store: store, design: design, initialWorkspaceID: Self.argument("-workspace")) {
                        self.design = nil
                    }
                }
        }
    }

    private static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

private struct DesignPicker: View {
    @Binding var design: WorkspacesDesign?

    var body: some View {
        NavigationStack {
            List(WorkspacesDesign.allCases) { option in
                Button { design = option } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.title).font(.headline).foregroundStyle(.primary)
                        Text(option.summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Workspaces designs")
            .safeAreaInset(edge: .bottom) {
                Text("Inside a design, tap your avatar and choose Switch Design to come back.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }
}
