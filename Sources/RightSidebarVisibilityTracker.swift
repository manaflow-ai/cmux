import Combine
import Foundation

@MainActor
final class RightSidebarVisibilityTracker: ObservableObject {
    static let shared = RightSidebarVisibilityTracker()

    @Published private(set) var isVisible: Bool = false

    private weak var boundState: FileExplorerState?
    private var cancellable: AnyCancellable?

    private init() {}

    /// Mirror the active main window's `FileExplorerState.isVisible`.
    /// AppDelegate calls this whenever the active main window context changes
    /// so menus and other top-level SwiftUI surfaces can render labels for the
    /// focused window's sidebar instead of relying on the global UserDefaults
    /// key (which can desync across multiple windows).
    func bind(to state: FileExplorerState?) {
        cancellable = nil
        boundState = state
        guard let state else {
            if isVisible { isVisible = false }
            return
        }
        if isVisible != state.isVisible {
            isVisible = state.isVisible
        }
        cancellable = state.$isVisible
            .removeDuplicates()
            .sink { [weak self] newValue in
                self?.isVisible = newValue
            }
    }

    /// Toggle the bound `FileExplorerState`. Use this from menus or the
    /// command palette so the state we mutate is the same one whose
    /// `isVisible` drives the menu/palette label — eliminating the
    /// title/action desync that `NSApp.keyWindow`-based dispatch can
    /// introduce when a non-main window is briefly key.
    @discardableResult
    func toggle() -> Bool {
        guard let state = boundState else { return false }
        state.toggle()
        return true
    }
}
