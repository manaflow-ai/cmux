#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import Foundation
import SwiftUI

/// Editor for the terminal input-accessory shortcut bar: toggle which buttons
/// appear, drag to reorder them, and add/edit/delete custom actions and menus.
/// Every bar button is listed, including the modifier keys (⌃ ⌥ ⌘), zoom, and
/// paste, so their position is customizable too. Backed by
/// ``TerminalAccessoryConfiguration``, so edits apply to the live bar immediately.
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
    @State private var isAddingMenu = false
    @State private var editingAction: CustomToolbarAction?

    init(scope: TerminalShortcutsSettingsScope = .terminal) {
        self.scope = scope
    }

    var body: some View {
        let rowActions = ShortcutRowActions(
            setEnabled: { id, isEnabled in configuration.setEnabled(id, isEnabled) },
            removeCustomAction: { id in configuration.removeCustomAction(id: id) },
            editCustomAction: { action in editingAction = action }
        )

        NavigationStack {
            List {
                Section {
                    ForEach(displayedRows) { row in
                        rowView(for: row, actions: rowActions)
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

                    if scope == .terminal {
                        Button {
                            isAddingMenu = true
                        } label: {
                            Label(
                                L10n.string("mobile.shortcuts.addMenu", defaultValue: "Add Menu"),
                                systemImage: "ellipsis.circle"
                            )
                        }
                        .accessibilityIdentifier("TerminalShortcutsAddMenuButton")
                    }
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
            .sheet(isPresented: $isAddingMenu) {
                CustomToolbarMenuEditorView(action: nil) { configuration.addCustomAction($0) }
            }
            .sheet(item: $editingAction) { action in
                if action.isMenu {
                    CustomToolbarMenuEditorView(action: action) { configuration.updateCustomAction($0) }
                } else {
                    CustomToolbarActionEditorView(action: action) { configuration.updateCustomAction($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(
        for row: ShortcutRowSnapshot,
        actions: ShortcutRowActions
    ) -> some View {
        Toggle(isOn: Binding(
            get: { row.isEnabled },
            set: { actions.setEnabled(row.id, $0) }
        )) {
            if row.isCustom {
                Label(row.settingsDisplayName, systemImage: row.symbolName)
            } else {
                Text(row.settingsDisplayName)
            }
        }
        .accessibilityIdentifier("TerminalShortcutToggle.\(row.id.storageKey)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let custom = row.customAction {
                Button(role: .destructive) {
                    actions.removeCustomAction(custom.id)
                } label: {
                    Label(L10n.string("mobile.common.delete", defaultValue: "Delete"), systemImage: "trash")
                }
                .accessibilityIdentifier("TerminalShortcutDelete.\(custom.id.uuidString)")

                Button {
                    actions.editCustomAction(custom)
                } label: {
                    Label(L10n.string("mobile.common.edit", defaultValue: "Edit"), systemImage: "pencil")
                }
                .tint(.blue)
                .accessibilityIdentifier("TerminalShortcutEdit.\(custom.id.uuidString)")
            }
        }
    }

    private var displayedItems: [ResolvedToolbarItem] {
        configuration.displayItems.filter(scope.includes)
    }

    private var displayedRows: [ShortcutRowSnapshot] {
        displayedItems.map { item in
            ShortcutRowSnapshot(item: item, isEnabled: configuration.isEnabled(item.id))
        }
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

private struct ShortcutRowSnapshot: Identifiable {
    let item: ResolvedToolbarItem
    let isEnabled: Bool

    var id: ToolbarItemID {
        item.id
    }

    var isCustom: Bool {
        item.isCustom
    }

    var customAction: CustomToolbarAction? {
        item.customAction
    }

    var settingsDisplayName: String {
        item.settingsDisplayName
    }

    var symbolName: String {
        guard let customAction else { return "character.cursor.ibeam" }
        if customAction.isMenu { return "ellipsis.circle" }
        return "character.cursor.ibeam"
    }
}

private struct ShortcutRowActions {
    let setEnabled: (ToolbarItemID, Bool) -> Void
    let removeCustomAction: (UUID) -> Void
    let editCustomAction: (CustomToolbarAction) -> Void
}
#endif
