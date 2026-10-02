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
    var isActive = true
    var hidesRootNavigationBar = false
    var managesTabBarVisibility = true
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (MobileWorkspacePreview.ID) -> Destination

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .mobileToolbarVisibility(rootNavigationBarVisibility, for: .navigationBar)
                .modifier(MobilePrimarySearchLifecycleModifier(
                    scope: searchCoordinator.scope,
                    update: { scope, isSearching in
                        guard isActive || !isSearching else { return }
                        searchCoordinator.updateLifecycle(scope: scope, isSearching: isSearching)
                    }
                ))
                .navigationDestination(for: MobileWorkspacePreview.ID.self, destination: destination)
        }
        .searchable(text: searchText, isPresented: searchPresentation, prompt: prompt)
        .onSubmit(of: .search) {
            guard isActive else { return }
            selection = searchCoordinator.commitSubmit()
        }
        .modifier(MobilePrimarySearchTabBarVisibilityModifier(
            isEnabled: managesTabBarVisibility,
            visibility: path.isEmpty ? .automatic : .hidden
        ))
    }

    private var searchPresentation: Binding<Bool> {
        Binding(
            get: { searchCoordinator.isPresented },
            set: { presented in
                searchCoordinator.setPresentation(presented)
            }
        )
    }

    private var rootNavigationBarVisibility: Visibility {
        if #available(iOS 26.0, *), hidesRootNavigationBar {
            return .hidden
        }
        return .automatic
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
        case .feed:
            Text(L10n.string("mobile.agentFeed.search.placeholder", defaultValue: "Search Feed"))
        case .notifications:
            Text(L10n.string("mobile.notificationFeed.search.placeholder", defaultValue: "Search notifications"))
        }
    }
}
#endif
