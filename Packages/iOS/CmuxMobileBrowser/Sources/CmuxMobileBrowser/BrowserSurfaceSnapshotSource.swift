import Observation

/// Equality-filtered observable snapshot storage for one workspace browser.
@MainActor
@Observable
final class BrowserSurfaceSnapshotSource {
    private(set) var value: BrowserSurfaceSnapshot

    init(value: BrowserSurfaceSnapshot) {
        self.value = value
    }

    func update(_ nextValue: BrowserSurfaceSnapshot) {
        guard nextValue != value else { return }
        value = nextValue
    }
}
