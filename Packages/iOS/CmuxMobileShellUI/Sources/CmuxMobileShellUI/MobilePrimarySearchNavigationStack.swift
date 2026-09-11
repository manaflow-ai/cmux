#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Keeps one search host alive across scope changes and workspace pushes.
/// Search presentation ends before navigation and returns to the native bottom
/// control, without recreating the field from a destination's disappearance.
struct MobilePrimarySearchNavigationStack<Root: View, Destination: View>: View {
    @Binding var path: [MobileWorkspacePreview.ID]
    @Binding var selection: MobilePrimaryTab
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (MobileWorkspacePreview.ID) -> Destination

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .modifier(MobilePrimarySearchLifecycleModifier(
                    scope: searchCoordinator.scope,
                    update: searchCoordinator.updateLifecycle
                ))
                .navigationDestination(for: MobileWorkspacePreview.ID.self, destination: destination)
        }
        .searchable(text: searchText, isPresented: searchPresentation, prompt: prompt)
        .onSubmit(of: .search) {
            selection = searchCoordinator.commitSubmit()
        }
        .toolbarVisibility(path.isEmpty ? .automatic : .hidden, for: .tabBar)
    }

    private var searchPresentation: Binding<Bool> {
        Binding(
            get: { searchCoordinator.isPresented },
            set: { presented in
                searchCoordinator.setPresentation(presented)
            }
        )
    }

    private var searchText: Binding<String> {
        let scope = searchCoordinator.scope
        let generation = searchCoordinator.activationGeneration
        return Binding(
            get: { searchCoordinator.nativeSearchText(for: scope) },
            set: { text in
                searchCoordinator.updateNativeSearchText(
                    text, for: scope, activationGeneration: generation
                )
            }
        )
    }

    private var prompt: Text {
        switch searchCoordinator.scope {
        case .workspaces:
            Text(L10n.string("mobile.workspaces.search.placeholder", defaultValue: "Search workspaces"))
        case .notifications:
            Text(L10n.string("mobile.notificationFeed.search.placeholder", defaultValue: "Search notifications"))
        }
    }
}
#endif
