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

    public func makeCoordinator() -> ThemedPickerCoordinator { ThemedPickerCoordinator(choose: choose) }

    public func makeNSView(context: Context) -> ThemedPopUpButton {
        let popup = ThemedPopUpButton(frame: .zero, pullsDown: false)
        popup.target = context.coordinator
        popup.action = #selector(ThemedPickerCoordinator.chose(_:))
        return popup
    }

    public func updateNSView(_ popup: ThemedPopUpButton, context: Context) {
        context.coordinator.choose = choose
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

    /// Sets the binding to the chosen item's id (an index outside the choices changes nothing).
    private var choose: (Int) -> Void {
        let choices = choices
        let selection = $selection
        return { index in
            guard choices.indices.contains(index) else { return }
            selection.wrappedValue = choices[index].id
        }
    }
}

/// Carries a `ThemedPicker`'s choice to its binding.
///
/// Not nested in the generic `ThemedPicker`: Swift 6.3.3's EarlyPerfInliner crashed
/// (`isCallerAndCalleeLayoutConstraintsCompatible`) on the deinit of a generic `NSObject`
/// subclass here in the Release build, so the coordinator is not generic and holds the
/// picker's choice as a closure.
@MainActor public final class ThemedPickerCoordinator: NSObject {
    fileprivate var choose: (Int) -> Void

    fileprivate init(choose: @escaping (Int) -> Void) { self.choose = choose }

    @objc fileprivate func chose(_ popup: NSPopUpButton) {
        choose(popup.indexOfSelectedItem)
    }
}
