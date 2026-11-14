#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

/// The production command palette on an isolated fixture, for material captures.
public struct CommandPaletteMaterialGallery: View {
    private let material: CmuxMobileTransientMaterial?
    @State private var source: WorkspaceTabsSource

    /// Nil draws the exact pre-unification system presentation.
    public init(material: CmuxMobileTransientMaterial?) {
        self.material = material
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "t-zsh"]))
        store.requestOpen(tabID: "t-zsh", in: "ws-cmux")
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        _source = State(initialValue: WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", creator: creator))
    }

    public var body: some View {
        Button("Open Command Palette") { source.openPalette() }
            .accessibilityIdentifier("transient.openPalette")
            .sheet(item: Binding(get: { source.palette }, set: { source.palette = $0 })) { scope in
                CommandPaletteSheet(source: source, scope: scope, material: material)
                    .presentationDetents([.large])
                    .onDisappear { source.paletteDismissed() }
            }
    }
}
#endif
