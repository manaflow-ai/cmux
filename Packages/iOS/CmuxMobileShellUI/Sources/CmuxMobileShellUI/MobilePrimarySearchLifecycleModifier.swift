#if os(iOS)
import CmuxMobileSupport
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
    @FocusState private var fieldIsFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: searchText,
                isPresented: presentation,
                prompt: prompt
            )
            .searchFocused($fieldIsFocused)
            .onSubmit(of: .search, submit)
            // Focus-engine activation: restoring a session around a pushed
            // detail re-presents through the FOCUS route rather than the
            // isPresented binding, which the platform hosts in the top
            // navigation drawer when driven programmatically.
            .onChange(of: searchCoordinator.focusRestoreRequest(for: scope)) { _, request in
                guard request > 0 else { return }
                fieldIsFocused = true
            }
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
