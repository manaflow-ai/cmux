#if os(iOS)
import SwiftUI
import UIKit

public extension View {
    /// The app's list search (Home and Workspaces alike): the native
    /// navigation-bar drawer, tucked under the bar on launch so it appears on
    /// a pull-down (ChatGPT, Mail). One modifier so both tabs look and behave
    /// the same.
    func cmuxMobilePullDownSearch(text: Binding<String>) -> some View {
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .background { PullDownSearch() }
    }
}

/// Starts the list with the search field tucked under the navigation bar,
/// so it appears on a pull-down (ChatGPT, Mail). `.searchable`'s drawer is
/// otherwise open at the top on launch; UIKit hides it once the list's
/// offset passes the field, so the list starts that far down, once.
struct PullDownSearch: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        private var done = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !done else { return }
            DispatchQueue.main.async { [weak self] in self?.tuck() }
        }

        private func tuck() {
            guard !done, let controller = owningController(),
                  let search = Self.navigationItemWithSearch(from: controller)?.searchController?.searchBar,
                  let scroll = Self.firstCollectionView(in: controller.view) else { return }
            done = true
            let height = search.frame.height
            guard height > 0, scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1 else { return }
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top + height), animated: false)
            // The collapsed drawer shrinks the top inset; settle on the new top
            // so the first row sits right under the bar.
            DispatchQueue.main.async {
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            }
        }

        private func owningController() -> UIViewController? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller }
                responder = next
            }
            return nil
        }

        /// This controller's or an ancestor's navigation item that carries the search controller.
        private static func navigationItemWithSearch(from start: UIViewController) -> UINavigationItem? {
            var controller: UIViewController? = start
            while let current = controller {
                if current.navigationItem.searchController != nil { return current.navigationItem }
                controller = current.parent
            }
            return nil
        }

        private static func firstCollectionView(in view: UIView) -> UICollectionView? {
            for subview in view.subviews {
                if let match = subview as? UICollectionView { return match }
                if let match = firstCollectionView(in: subview) { return match }
            }
            return nil
        }
    }
}
#endif
