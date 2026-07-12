import CmuxMobileSupport
import SwiftUI
import UIKit

/// A UIKit-backed search field whose lifecycle is independent from SwiftUI's
/// search environment. Live workspace snapshots can rebuild the list without
/// asking AttributeGraph to recreate a `SearchEnvironmentWritingModifier`.
@MainActor
struct WorkspaceSearchBar: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.delegate = context.coordinator
        searchBar.searchTextField.accessibilityIdentifier = "MobileWorkspaceSearchField"
        configure(searchBar)
        return searchBar
    }

    func updateUIView(_ searchBar: UISearchBar, context: Context) {
        context.coordinator.text = $text
        configure(searchBar)
        if searchBar.text != text {
            searchBar.text = text
        }
    }

    static func dismantleUIView(_ searchBar: UISearchBar, coordinator: Coordinator) {
        searchBar.delegate = nil
    }

    private func configure(_ searchBar: UISearchBar) {
        searchBar.placeholder = L10n.string(
            "mobile.workspaces.search.placeholder",
            defaultValue: "Search Workspaces"
        )
    }

    @MainActor
    final class Coordinator: NSObject, UISearchBarDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard text.wrappedValue != searchText else { return }
            text.wrappedValue = searchText
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }
}
