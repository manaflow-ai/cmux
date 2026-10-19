import AppKit
import CmuxNextDaemon
import CmuxNextSettings

/// Opens what the person opened from a pane (red commit: the old behavior, a tab in the source).
@MainActor
final class LinkOpener {
    typealias Make = @MainActor (_ pane: PaneController, _ placed: (@MainActor (SurfaceID) -> Void)?) -> Bool
    private weak var services: AppServices?
    var placement: () -> LinkPlacement

    init(services: AppServices) {
        self.services = services
        placement = { [weak services] in services?.settings?.snapshot.linkPlacement ?? .fallback }
    }

    @discardableResult
    func open(from source: PaneController?, background: Bool = false, _ make: Make) -> Bool {
        guard let source = source ?? services?.windows.active?.focusedPane else { return false }
        return make(source, nil)
    }
}
