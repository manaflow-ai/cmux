import CmuxMobileSupport
import SwiftUI

/// Applies the platform search presentation to workspace snapshots that are
/// replaced during refresh. The query is owned by the surrounding shell so the
/// iOS 26 bottom control and older native drawer share one stable value.
@MainActor
struct WorkspaceListSearchHost<Content: View>: View {
    @Binding private var searchText: String
    @FocusState private var searchIsFocused: Bool
    private let usesBottomControl: Bool
    private let bottomControlIsPresented: Bool
    private let content: (String) -> Content

    init(
        searchText: Binding<String>,
        usesBottomControl: Bool,
        bottomControlIsPresented: Bool = false,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        _searchText = searchText
        self.usesBottomControl = usesBottomControl
        self.bottomControlIsPresented = bottomControlIsPresented
        self.content = content
    }

    var body: some View {
        #if os(iOS)
        iOSContent
        #else
        content(searchText)
            .searchable(text: $searchText)
            .searchFocused($searchIsFocused)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSContent: some View {
        if #available(iOS 26.0, *), usesBottomControl {
            // The iOS 26 shell presents search beside its floating tab bar.
            // Keeping `.searchable` here would create a second top-bar control.
            content(searchText)
                .toolbarVisibility(
                    bottomControlIsPresented ? .hidden : .automatic,
                    for: .tabBar
                )
        } else if #available(iOS 26.0, *) {
            content(searchText)
                .searchable(text: $searchText)
                .searchToolbarBehavior(.minimize)
                .searchFocused($searchIsFocused)
        } else {
            content(searchText)
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always)
                )
                .searchFocused($searchIsFocused)
        }
    }
    #endif
}

#if os(iOS)
/// The compact iOS 26 search affordance that sits beside the floating tab bar.
/// It expands in place only while the workspace root is visible.
@available(iOS 26.0, *)
@MainActor
private struct WorkspaceListBottomSearchControl: View {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    let taskComposerAction: (() -> Void)?
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        Group {
            if isPresented {
                expandedField
                    .padding(.horizontal, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
            } else {
                HStack(spacing: 12) {
                    if let taskComposerAction {
                        TaskComposerButton(
                            presentation: .compact,
                            action: taskComposerAction
                        )
                    }
                    Spacer(minLength: 0)
                    collapsedButton
                }
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.84, anchor: .bottomTrailing)))
            }
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            guard presented else {
                searchIsFocused = false
                return
            }
            Task { @MainActor in
                await Task.yield()
                guard isPresented else { return }
                searchIsFocused = true
            }
        }
    }

    private var collapsedButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.24)) {
                isPresented = true
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .mobileGlassPill()
        .accessibilityLabel(
            L10n.string("mobile.workspaces.search.button", defaultValue: "Search")
        )
        .accessibilityIdentifier("MobileWorkspaceSearchButton")
    }

    private var expandedField: some View {
        GlassInputPill(height: 52, alignment: .leading) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                L10n.string(
                    "mobile.workspaces.search.placeholder",
                    defaultValue: "Search workspaces"
                ),
                text: $searchText
            )
            .focused($searchIsFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityIdentifier("MobileWorkspaceSearchField")

            Button {
                searchText = ""
                withAnimation(.snappy(duration: 0.2)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                L10n.string("mobile.workspaces.search.close", defaultValue: "Close search")
            )
            .accessibilityIdentifier("MobileWorkspaceSearchCloseButton")
        } onTap: {
            searchIsFocused = true
        }
    }
}

@available(iOS 26.0, *)
@MainActor
private struct WorkspaceListBottomSearchModifier: ViewModifier {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    let isVisible: Bool
    let taskComposerAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if isVisible {
                    WorkspaceListBottomSearchControl(
                        searchText: $searchText,
                        isPresented: $isPresented,
                        taskComposerAction: taskComposerAction
                    )
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: isVisible) { _, visible in
                guard !visible else { return }
                searchText = ""
                isPresented = false
            }
    }
}

extension View {
    /// Adds the iOS 26 search orb without changing the identity of the TabView
    /// or its navigation stacks. Older iOS versions keep the native drawer from
    /// ``WorkspaceListSearchHost``.
    @MainActor
    @ViewBuilder
    func workspaceListBottomSearch(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        isVisible: Bool,
        taskComposerAction: (() -> Void)? = nil
    ) -> some View {
        if #available(iOS 26.0, *) {
            modifier(
                WorkspaceListBottomSearchModifier(
                    searchText: text,
                    isPresented: isPresented,
                    isVisible: isVisible,
                    taskComposerAction: taskComposerAction
                )
            )
        } else {
            self
        }
    }
}
#endif
