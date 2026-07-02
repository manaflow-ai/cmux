#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import SwiftUI

/// Editor for the terminal input-accessory shortcut bar: toggle which buttons
/// appear, drag to reorder them, and add/edit/delete custom actions. Every bar
/// button is listed, including the modifier keys (⌃ ⌥ ⌘), zoom, and paste, so
/// their position is customizable too. Backed by ``TerminalAccessoryConfiguration``,
/// so edits apply to the live bar immediately.
struct TerminalShortcutsSettingsView: View {
    // TRANSITIONAL: TerminalAccessoryConfiguration.shared is also read by the
    // off-limits typing-latency render path (TerminalInputTextView); inverting it
    // to an injected store requires threading it through that path, which is
    // reserved for the terminal-surface wave. Until then this view keeps the
    // singleton reach-in so behavior stays identical.
    private var configuration: TerminalAccessoryConfiguration { .shared }
    private let scope: TerminalShortcutsSettingsScope
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingAction = false
    @State private var editingAction: CustomToolbarAction?

    init(scope: TerminalShortcutsSettingsScope = .terminal) {
        self.scope = scope
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(displayedItems) { item in
                        row(for: item)
                    }
                    .onMove(perform: moveDisplayedItems)
                } header: {
                    Text(L10n.string("mobile.shortcuts.header", defaultValue: "Shortcut Buttons"))
                } footer: {
                    Text(scope.footer)
                }

                Section {
                    Button {
                        isAddingAction = true
                    } label: {
                        Label(
                            L10n.string("mobile.shortcuts.addAction", defaultValue: "Add Custom Action"),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("TerminalShortcutsAddActionButton")
                }

                Section {
                    Button(role: .destructive) {
                        configuration.resetToDefaults()
                    } label: {
                        Text(L10n.string("mobile.shortcuts.reset", defaultValue: "Reset to Defaults"))
                    }
                    .accessibilityIdentifier("TerminalShortcutsResetButton")
                }
            }
            .navigationTitle(scope.navigationTitle)
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .accessibilityIdentifier("TerminalShortcutsEditButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("TerminalShortcutsDoneButton")
                }
            }
            .sheet(isPresented: $isAddingAction) {
                CustomToolbarActionEditorView(action: nil) { configuration.addCustomAction($0) }
            }
            .sheet(item: $editingAction) { action in
                CustomToolbarActionEditorView(action: action) { configuration.updateCustomAction($0) }
            }
        }
    }

    @ViewBuilder
    private func row(for item: ResolvedToolbarItem) -> some View {
        Toggle(isOn: binding(for: item.id)) {
            if item.isCustom {
                Label(item.settingsDisplayName, systemImage: "character.cursor.ibeam")
            } else {
                Text(item.settingsDisplayName)
            }
        }
        .accessibilityIdentifier("TerminalShortcutToggle.\(item.id.storageKey)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let custom = item.customAction {
                Button(role: .destructive) {
                    configuration.removeCustomAction(id: custom.id)
                } label: {
                    Label(L10n.string("mobile.common.delete", defaultValue: "Delete"), systemImage: "trash")
                }
                .accessibilityIdentifier("TerminalShortcutDelete.\(custom.id.uuidString)")

                Button {
                    editingAction = custom
                } label: {
                    Label(L10n.string("mobile.common.edit", defaultValue: "Edit"), systemImage: "pencil")
                }
                .tint(.blue)
                .accessibilityIdentifier("TerminalShortcutEdit.\(custom.id.uuidString)")
            }
        }
    }

    private func binding(for id: ToolbarItemID) -> Binding<Bool> {
        Binding(
            get: { configuration.isEnabled(id) },
            set: { configuration.setEnabled(id, $0) }
        )
    }

    private var displayedItems: [ResolvedToolbarItem] {
        configuration.displayItems.filter(scope.includes)
    }

    private func moveDisplayedItems(from offsets: IndexSet, to destination: Int) {
        guard scope != .terminal else {
            configuration.moveItems(from: offsets, to: destination)
            return
        }

        let visibleIDs = displayedItems.map(\.id)
        let visibleSet = Set(visibleIDs)
        var reorderedVisibleIDs = visibleIDs
        reorderedVisibleIDs.move(fromOffsets: offsets, toOffset: destination)
        var visibleIterator = reorderedVisibleIDs.makeIterator()
        let reorderedFullIDs = configuration.displayOrder.map { id in
            guard visibleSet.contains(id) else { return id }
            return visibleIterator.next() ?? id
        }
        configuration.reorderItems(reorderedFullIDs)
    }
}
#endif
