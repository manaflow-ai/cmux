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
        let seed = Self.seed(from: action)
        _title = State(initialValue: seed.title)
        _items = State(initialValue: seed.items)
    }

    var body: some View {
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
                    ForEach(items.indices, id: \.self) { index in
                        itemEditor(at: index)
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

    @ViewBuilder
    private func itemEditor(at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                format: L10n.string(
                    "mobile.toolbar.menuEditor.itemHeaderFormat",
                    defaultValue: "Item %d"
                ),
                index + 1
            ))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)

            TextField(
                L10n.string(
                    "mobile.toolbar.menuEditor.itemTitlePlaceholder",
                    defaultValue: "Item label"
                ),
                text: $items[index].title
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("CustomMenuItemTitleField.\(items[index].id.uuidString)")

            TextField(
                L10n.string("mobile.toolbar.menuEditor.itemCommandPlaceholder", defaultValue: "npm test"),
                text: $items[index].commandText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.body, design: .monospaced))
            .accessibilityIdentifier("CustomMenuItemCommandField.\(items[index].id.uuidString)")

            Toggle(isOn: $items[index].runAfterTyping) {
                Text(L10n.string("mobile.toolbar.editor.runAfterTyping", defaultValue: "Run after typing"))
            }
            .accessibilityIdentifier("CustomMenuItemRunToggle.\(items[index].id.uuidString)")

            Button(role: .destructive) {
                removeItem(id: items[index].id)
            } label: {
                Label(
                    L10n.string("mobile.toolbar.menuEditor.removeItem", defaultValue: "Remove Item"),
                    systemImage: "trash"
                )
            }
            .accessibilityIdentifier("CustomMenuItemRemoveButton.\(items[index].id.uuidString)")
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

    private static func seed(
        from action: CustomToolbarAction?
    ) -> (title: String, items: [CustomToolbarMenuDraftItem]) {
        guard let action, case let .menu(storedItems) = action.payload else {
            return ("", [CustomToolbarMenuDraftItem()])
        }
        let drafts = storedItems.map(CustomToolbarMenuDraftItem.init(menuItem:))
        return (action.title, drafts.isEmpty ? [CustomToolbarMenuDraftItem()] : drafts)
    }
}
#endif
