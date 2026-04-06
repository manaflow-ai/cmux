import Foundation

/// Observable state for the file browser drawer panel.
/// Mirrors the pattern used by `SidebarState` in `ContentView.swift`.
@MainActor
final class FileBrowserDrawerState: ObservableObject {
    @Published var isVisible: Bool
    @Published var persistedWidth: CGFloat

    init(
        isVisible: Bool = false,
        persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultDrawerWidth)
    ) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedDrawerWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        isVisible.toggle()
    }
}
