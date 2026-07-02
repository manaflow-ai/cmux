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
                if scope == .terminal {
                    Section {
                        Stepper(
                            value: rowCountBinding,
                            in: TerminalAccessoryConfiguration.minimumRowCount...TerminalAccessoryConfiguration.maximumRowCount
                        ) {
                            HStack {
                                Text(L10n.string("mobile.shortcuts.rows.label", defaultValue: "Rows"))
                                Spacer()
                                Text("\(configuration.rowCount)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("TerminalShortcutsRowCountStepper")
                    } header: {
                        Text(L10n.string("mobile.shortcuts.rows.header", defaultValue: "Toolbar Rows"))
                    } footer: {
                        Text(L10n.string(
                            "mobile.shortcuts.rows.footer",
                            defaultValue: "Add rows to keep more buttons visible above the keyboard."
                        ))
                    }

                    ForEach(displayedRowSections) { rowSection in
                        Section {
                            ForEach(rowSection.items) { item in
                                row(for: item, rowIndex: rowSection.index)
                            }
                            .onMove { offsets, destination in
                                moveDisplayedItems(from: offsets, to: destination, inRow: rowSection.index)
                            }
                        } header: {
                            Text(rowTitle(rowSection.index))
                        } footer: {
                            if rowSection.index == displayedRowSections.count - 1 {
                                Text(scope.footer)
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(displayedItems) { item in
                            row(for: item, rowIndex: nil)
                        }
                        .onMove(perform: moveDisplayedItems)
                    } header: {
                        Text(L10n.string("mobile.shortcuts.header", defaultValue: "Shortcut Buttons"))
                    } footer: {
                        Text(scope.footer)
                    }
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
    private func row(for item: ResolvedToolbarItem, rowIndex: Int?) -> some View {
        HStack {
            Toggle(isOn: binding(for: item.id)) {
                if item.isCustom {
                    Label(item.settingsDisplayName, systemImage: "character.cursor.ibeam")
                } else {
                    Text(item.settingsDisplayName)
                }
            }

            if scope == .terminal, configuration.rowCount > 1 {
                Picker(
                    L10n.string("mobile.shortcuts.rows.movePicker", defaultValue: "Move to Row"),
                    selection: rowBinding(for: item.id, fallback: rowIndex ?? 0)
                ) {
                    ForEach(0..<configuration.rowCount, id: \.self) { index in
                        Text(rowTitle(index)).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("TerminalShortcutRowPicker.\(item.id.storageKey)")
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

    private var rowCountBinding: Binding<Int> {
        Binding(
            get: { configuration.rowCount },
            set: { configuration.setRowCount($0) }
        )
    }

    private func rowBinding(for id: ToolbarItemID, fallback: Int) -> Binding<Int> {
        Binding(
            get: { rowIndex(for: id) ?? fallback },
            set: { configuration.moveItem(id, toRow: $0) }
        )
    }

    private var displayedItems: [ResolvedToolbarItem] {
        configuration.displayItems.filter(scope.includes)
    }

    private var displayedItemRows: [[ResolvedToolbarItem]] {
        configuration.displayItemRows.map { row in row.filter(scope.includes) }
    }

    private var displayedRowSections: [TerminalShortcutRowSection] {
        displayedItemRows.enumerated().map { index, items in
            TerminalShortcutRowSection(
                id: "terminal-shortcuts-row-\(index)",
                index: index,
                items: items
            )
        }
    }

    private func rowIndex(for id: ToolbarItemID) -> Int? {
        configuration.displayRows.firstIndex { row in row.contains(id) }
    }

    private func rowTitle(_ rowIndex: Int) -> String {
        String(
            format: L10n.string("mobile.shortcuts.rows.rowTitleFormat", defaultValue: "Row %d"),
            rowIndex + 1
        )
    }

    private func moveDisplayedItems(from offsets: IndexSet, to destination: Int) {
        // Agent-chat ("Shared Shortcuts") scope only: a single flat list whose items
        // may be spread across several terminal rows. Reorder strictly *within* each
        // item's current row (`limitedTo:`) so a drag never silently reshuffles the
        // terminal row layout. A flat reorder cannot move one item across a
        // fixed-length row boundary without either changing row lengths or cascading
        // another item into a different row — the silent row scramble fixed for this
        // path. Cross-row moves are intentionally routed through the Terminal
        // Shortcuts per-item row picker (`moveItem(_:toRow:)`) instead.
        let visibleIDs = displayedItems.map(\.id)
        let visibleSet = Set(visibleIDs)
        var reorderedVisibleIDs = visibleIDs
        reorderedVisibleIDs.move(fromOffsets: offsets, toOffset: destination)
        configuration.reorderItems(reorderedVisibleIDs, limitedTo: visibleSet)
    }

    private func moveDisplayedItems(from offsets: IndexSet, to destination: Int, inRow rowIndex: Int) {
        configuration.moveItems(from: offsets, to: destination, inRow: rowIndex)
    }
}
#endif
