#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import SwiftUI

/// Create or edit a user-defined terminal toolbar dropdown menu.
///
/// A menu action appears as one toolbar button. Tapping it opens a native iOS
/// menu, and selecting a menu item sends that item's text to the terminal.
struct CustomToolbarMenuEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existing: CustomToolbarAction?
    private let onSave: (CustomToolbarAction) -> Void

    @State private var title: String
    @State private var items: [CustomToolbarMenuDraftItem]

    /// Creates the menu editor.
    /// - Parameters:
    ///   - action: The menu action to edit, or `nil` to create a new one.
    ///   - onSave: Called with the resulting menu action when the user taps Save.
    init(action: CustomToolbarAction?, onSave: @escaping (CustomToolbarAction) -> Void) {
        self.existing = action
        self.onSave = onSave
        if let action, case let .menu(storedItems) = action.payload {
            let drafts = storedItems.map(CustomToolbarMenuDraftItem.init(menuItem:))
            _title = State(initialValue: action.title)
            _items = State(initialValue: drafts.isEmpty ? [CustomToolbarMenuDraftItem()] : drafts)
        } else {
            _title = State(initialValue: "")
            _items = State(initialValue: [CustomToolbarMenuDraftItem()])
        }
    }

    var body: some View {
        let ordinalsByID = itemOrdinalsByID

        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.string("mobile.toolbar.menuEditor.titlePlaceholder", defaultValue: "Menu label"),
                        text: $title
                    )
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("CustomMenuTitleField")
                } header: {
                    Text(L10n.string("mobile.toolbar.menuEditor.titleHeader", defaultValue: "Label"))
                } footer: {
                    Text(L10n.string(
                        "mobile.toolbar.menuEditor.titleFooter",
                        defaultValue: "Shown on the toolbar button that opens the menu."
                    ))
                }

                Section {
                    ForEach($items) { item in
                        itemEditor(
                            item,
                            ordinal: ordinalsByID[item.wrappedValue.id, default: 1]
                        )
                    }

                    Button {
                        items.append(CustomToolbarMenuDraftItem())
                    } label: {
                        Label(
                            L10n.string("mobile.toolbar.menuEditor.addItem", defaultValue: "Add Menu Item"),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("CustomMenuAddItemButton")
                } header: {
                    Text(L10n.string("mobile.toolbar.menuEditor.itemsHeader", defaultValue: "Menu Items"))
                } footer: {
                    Text(L10n.string(
                        "mobile.toolbar.menuEditor.itemsFooter",
                        defaultValue: "Each item sends text to the terminal. Turn on Run after typing to press Return automatically."
                    ))
                }
            }
            .navigationTitle(navigationTitle)
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("CustomMenuCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        save()
                    }
                    .disabled(!isValid)
                    .accessibilityIdentifier("CustomMenuSaveButton")
                }
            }
        }
    }

    private var navigationTitle: String {
        existing == nil
            ? L10n.string("mobile.toolbar.menuEditor.addTitle", defaultValue: "Add Menu")
            : L10n.string("mobile.toolbar.menuEditor.editTitle", defaultValue: "Edit Menu")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedTitle.isEmpty && !items.isEmpty && items.allSatisfy(\.isValid)
    }

    private var itemOrdinalsByID: [UUID: Int] {
        var ordinals: [UUID: Int] = [:]
        for (index, item) in items.enumerated() {
            ordinals[item.id] = index + 1
        }
        return ordinals
    }

    @ViewBuilder
    private func itemEditor(
        _ item: Binding<CustomToolbarMenuDraftItem>,
        ordinal: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                format: L10n.string(
                    "mobile.toolbar.menuEditor.itemHeaderFormat",
                    defaultValue: "Item %d"
                ),
                ordinal
            ))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)

            TextField(
                L10n.string(
                    "mobile.toolbar.menuEditor.itemTitlePlaceholder",
                    defaultValue: "Item label"
                ),
                text: item.title
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("CustomMenuItemTitleField.\(item.wrappedValue.id.uuidString)")

            TextField(
                L10n.string("mobile.toolbar.menuEditor.itemCommandPlaceholder", defaultValue: "npm test"),
                text: item.commandText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.body, design: .monospaced))
            .accessibilityIdentifier("CustomMenuItemCommandField.\(item.wrappedValue.id.uuidString)")

            Toggle(isOn: item.runAfterTyping) {
                Text(L10n.string("mobile.toolbar.editor.runAfterTyping", defaultValue: "Run after typing"))
            }
            .accessibilityIdentifier("CustomMenuItemRunToggle.\(item.wrappedValue.id.uuidString)")

            Button(role: .destructive) {
                removeItem(id: item.wrappedValue.id)
            } label: {
                Label(
                    L10n.string("mobile.toolbar.menuEditor.removeItem", defaultValue: "Remove Item"),
                    systemImage: "trash"
                )
            }
            .accessibilityIdentifier("CustomMenuItemRemoveButton.\(item.wrappedValue.id.uuidString)")
        }
        .padding(.vertical, 4)
    }

    private func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
    }

    private func save() {
        guard isValid else { return }
        let menuItems = items.map(\.toolbarMenuItem)
        let action = CustomToolbarAction(
            id: existing?.id ?? UUID(),
            title: trimmedTitle,
            symbolName: existing?.symbolName,
            payload: .menu(menuItems)
        )
        onSave(action)
        dismiss()
    }

}
#endif
