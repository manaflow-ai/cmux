#if os(iOS)
import SwiftUI

struct MobilePrimarySearchLifecycleModifier: ViewModifier {
    @Environment(\.isSearching) private var isSearching

    let scope: MobilePrimarySearchScope
    let update: (MobilePrimarySearchScope, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isSearching, initial: true) { _, isSearching in
                update(scope, isSearching)
            }
            .onDisappear {
                update(scope, false)
            }
    }
}

/// Attaches one search scope's native field to the ROOT view inside that
/// scope's NavigationStack. Rooted there, the platform owns the field's
/// push-minimize/pop-restore lifecycle: pushing a detail collapses the field
/// and popping back restores it at the search tab's bottom control with the
/// query intact. Attached outside the stack (the old shape), a restored
/// presentation re-hosts in the top navigation bar and drops the query.
struct MobilePrimarySearchFieldModifier: ViewModifier {
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let scope: MobilePrimarySearchScope
    let submit: () -> Void

    func body(content: Content) -> some View {
        content
            .searchable(
                text: searchText,
                isPresented: presentation,
                prompt: prompt
            )
            .onSubmit(of: .search, submit)
    }

    private var searchText: Binding<String> {
        let scope = scope
        let activationGeneration = searchCoordinator.activationGeneration
        return Binding(
            get: { searchCoordinator.nativeSearchText(for: scope) },
            set: { value in
                searchCoordinator.updateNativeSearchText(
                    value,
                    for: scope,
                    activationGeneration: activationGeneration
                )
            }
        )
    }

    private var presentation: Binding<Bool> {
        Binding(
            get: { searchCoordinator.isPresented },
            set: { presented in
                searchCoordinator.setPresentation(presented)
            }
        )
    }

    private var prompt: Text {
        switch scope {
        case .workspaces:
            Text(
                L10n.string(
                    "mobile.workspaces.search.placeholder",
                    defaultValue: "Search workspaces"
                )
            )
        case .notifications:
            Text(
                L10n.string(
                    "mobile.notificationFeed.search.placeholder",
                    defaultValue: "Search notifications"
                )
            )
        }
    }
}
#endif
