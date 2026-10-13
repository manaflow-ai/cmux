public import AppKit
public import SwiftUI

/// SwiftUI's pop-up `Picker` in the theme: a `ThemedPopUpButton`, whose bezel is the scope's
/// selection fill, for the panes whose stock picker drew macOS's gray whatever the room's theme.
/// Its menu is AppKit's (a platform limit, as every `NSMenu`). Keys and VoiceOver are the stock
/// pop-up's.
public struct ThemedPicker<ID: Hashable>: NSViewRepresentable {
    /// One menu item: what the binding holds and the title shown.
    public struct Choice {
        public let id: ID
        public let title: String

        public init(id: ID, title: String) {
            self.id = id
            self.title = title
        }
    }

    @Binding private var selection: ID
    private let choices: [Choice]
    private let identifier: String?

    /// - Parameters:
    ///   - selection: The chosen item's id.
    ///   - choices: The menu's items, in order.
    ///   - identifier: The pop-up's accessibility identifier.
    public init(selection: Binding<ID>, choices: [Choice], identifier: String? = nil) {
        _selection = selection
        self.choices = choices
        self.identifier = identifier
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> ThemedPopUpButton {
        let popup = ThemedPopUpButton(frame: .zero, pullsDown: false)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.chose(_:))
        return popup
    }

    public func updateNSView(_ popup: ThemedPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = choices.map(\.title)
        if popup.itemTitles != titles {
            popup.removeAllItems()
            // addItems(withTitles:) drops duplicate titles; the menu keeps every choice.
            for title in titles { popup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "") }
        }
        let index = choices.firstIndex { $0.id == selection } ?? -1
        if popup.indexOfSelectedItem != index { popup.selectItem(at: index) }
        if let identifier, popup.accessibilityIdentifier() != identifier { popup.setAccessibilityIdentifier(identifier) }
    }

    /// Carries the pop-up's choice to the binding.
    @MainActor public final class Coordinator: NSObject {
        fileprivate var parent: ThemedPicker

        fileprivate init(_ parent: ThemedPicker) { self.parent = parent }

        @objc fileprivate func chose(_ popup: NSPopUpButton) {
            let index = popup.indexOfSelectedItem
            guard parent.choices.indices.contains(index) else { return }
            parent.selection = parent.choices[index].id
        }
    }
}
