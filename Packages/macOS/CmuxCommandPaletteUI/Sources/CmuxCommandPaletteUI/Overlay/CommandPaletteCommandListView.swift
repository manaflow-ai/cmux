public import AppKit
public import SwiftUI
public import CmuxCommandPalette

/// The command/switcher list mode of the command palette overlay: a single-line
/// search field over the materialized command list, plus a hidden Escape button
/// that preserves Esc-to-close without showing footer controls.
///
/// Lifted out of `ContentView` so the palette's primary list body is an
/// explicit-typed `View` struct in the command-palette UI package. Every
/// host-side decision (keyboard-shortcut routing, result execution, scroll
/// retargeting, focus reset, search scheduling, debug-state sync) is injected
/// as a closure, so the view never reaches back into the app target.
public struct CommandPaletteCommandListView<ListContent: View>: View {
    @Bindable private var presentation: CommandPalettePresentationModel
    @Binding private var isSearchFocused: Bool
    private let placeholder: String

    private let onSubmit: () -> Void
    private let onEscape: () -> Void
    private let onMoveSelection: (Int) -> Void
    private let onUnhandledNavigationKey: (NSEvent) -> Bool
    private let fieldEditorNavigationDelta: (Selector, NSEvent?) -> Int?
    private let keyEventNavigationDelta: (NSEvent) -> Int?
    private let shouldSubmitWithReturn: (NSEvent) -> Bool

    private let onAppearUpdateScrollTarget: () -> Void
    private let onAppearResetSearchFocus: () -> Void
    private let onQueryChange: (_ oldQuery: String, _ newQuery: String) -> Void
    private let onSearchFingerprintChange: () -> Void
    private let onResultsRevisionChange: () -> Void
    private let onSelectedResultIndexChange: () -> Void
    private let searchFingerprint: Int
    @ViewBuilder private let listContent: () -> ListContent

    /// Creates the command-list view.
    /// - Parameters:
    ///   - presentation: The palette presentation model (query/selection/scroll state).
    ///   - isSearchFocused: Two-way binding bridging the host's `@FocusState`.
    ///   - placeholder: Localized placeholder for the search field.
    ///   - searchFingerprint: Host-computed fingerprint observed for forced corpus refreshes.
    ///   - onSubmit: Runs the selected result.
    ///   - onEscape: Dismisses the palette.
    ///   - onMoveSelection: Moves the selection by a delta.
    ///   - onUnhandledNavigationKey: Forwards an arrow key the field did not consume; returns whether handled.
    ///   - fieldEditorNavigationDelta: Maps a field-editor command to a selection delta.
    ///   - keyEventNavigationDelta: Maps a key event to a selection delta.
    ///   - shouldSubmitWithReturn: Returns whether a Return event should submit.
    ///   - onAppearUpdateScrollTarget: Updates the scroll target on appear.
    ///   - onAppearResetSearchFocus: Resets search-field focus on appear.
    ///   - onQueryChange: Handles a query transition (old, new).
    ///   - onSearchFingerprintChange: Handles a search-fingerprint transition.
    ///   - onResultsRevisionChange: Handles a results-revision transition.
    ///   - onSelectedResultIndexChange: Handles a selected-index transition.
    ///   - listContent: The materialized result-rows list (app-coupled rendering: accent color + label content).
    public init(
        presentation: CommandPalettePresentationModel,
        isSearchFocused: Binding<Bool>,
        placeholder: String,
        searchFingerprint: Int,
        onSubmit: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onMoveSelection: @escaping (Int) -> Void,
        onUnhandledNavigationKey: @escaping (NSEvent) -> Bool,
        fieldEditorNavigationDelta: @escaping (Selector, NSEvent?) -> Int?,
        keyEventNavigationDelta: @escaping (NSEvent) -> Int?,
        shouldSubmitWithReturn: @escaping (NSEvent) -> Bool,
        onAppearUpdateScrollTarget: @escaping () -> Void,
        onAppearResetSearchFocus: @escaping () -> Void,
        onQueryChange: @escaping (_ oldQuery: String, _ newQuery: String) -> Void,
        onSearchFingerprintChange: @escaping () -> Void,
        onResultsRevisionChange: @escaping () -> Void,
        onSelectedResultIndexChange: @escaping () -> Void,
        @ViewBuilder listContent: @escaping () -> ListContent
    ) {
        self._presentation = Bindable(presentation)
        self._isSearchFocused = isSearchFocused
        self.placeholder = placeholder
        self.searchFingerprint = searchFingerprint
        self.onSubmit = onSubmit
        self.onEscape = onEscape
        self.onMoveSelection = onMoveSelection
        self.onUnhandledNavigationKey = onUnhandledNavigationKey
        self.fieldEditorNavigationDelta = fieldEditorNavigationDelta
        self.keyEventNavigationDelta = keyEventNavigationDelta
        self.shouldSubmitWithReturn = shouldSubmitWithReturn
        self.onAppearUpdateScrollTarget = onAppearUpdateScrollTarget
        self.onAppearResetSearchFocus = onAppearResetSearchFocus
        self.onQueryChange = onQueryChange
        self.onSearchFingerprintChange = onSearchFingerprintChange
        self.onResultsRevisionChange = onResultsRevisionChange
        self.onSelectedResultIndexChange = onSelectedResultIndexChange
        self.listContent = listContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CommandPaletteSearchFieldRepresentable(
                    placeholder: placeholder,
                    text: $presentation.query,
                    isFocused: $isSearchFocused,
                    onSubmit: onSubmit,
                    onEscape: onEscape,
                    onMoveSelection: onMoveSelection,
                    onUnhandledNavigationKey: onUnhandledNavigationKey,
                    fieldEditorNavigationDelta: fieldEditorNavigationDelta,
                    keyEventNavigationDelta: keyEventNavigationDelta,
                    shouldSubmitWithReturn: shouldSubmitWithReturn
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            listContent()

            // Keep Esc-to-close behavior without showing footer controls.
            Button(action: onEscape) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            onAppearUpdateScrollTarget()
            onAppearResetSearchFocus()
        }
        .onChange(of: presentation.query) { oldValue, newValue in
            onQueryChange(oldValue, newValue)
        }
        .onChange(of: searchFingerprint) { _, _ in
            onSearchFingerprintChange()
        }
        .onChange(of: presentation.resultsRevision) { _, _ in
            onResultsRevisionChange()
        }
        .onChange(of: presentation.selectedResultIndex) { _, _ in
            onSelectedResultIndexChange()
        }
    }
}
