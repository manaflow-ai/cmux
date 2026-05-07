import Combine
import Foundation

@MainActor
final class RightSidebarVisibilityTracker: ObservableObject {
    static let shared = RightSidebarVisibilityTracker()

    @Published private(set) var isVisible: Bool = false

    private var cancellable: AnyCancellable?

    private init() {}

    /// Mirror the active main window's `FileExplorerState.isVisible`.
    /// AppDelegate calls this whenever the active main window context changes
    /// so menus and other top-level SwiftUI surfaces can render labels for the
    /// focused window's sidebar instead of relying on the global UserDefaults
    /// key (which can desync across multiple windows).
    func bind(to state: FileExplorerState?) {
        cancellable = nil
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
}
