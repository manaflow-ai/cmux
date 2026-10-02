public import Foundation
public import Observation

/// Computer use: one panel with both grants the helper app needs. Allow
/// opens that list in System Settings and floats a tile of the helper app
/// over it to drag in; the row turns Done by itself when the grant lands,
/// and the tile goes. Nothing is asked twice and nothing blocks Continue.
@MainActor
@Observable
public final class ComputerUseStepModel {
    public private(set) var permissions: ComputerUsePermissions = .none
    /// The list the drag tile is helping with, while it shows.
    public private(set) var helping: ComputerUsePermissionPane?
    @ObservationIgnored let source: (any ComputerUsePermissionSource)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(source: (any ComputerUsePermissionSource)?) {
        self.source = source
    }

    /// Follows the helper's grants while the step shows.
    func start() {
        guard task == nil, let source else { return }
        let stream = source.permissions()
        task = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                permissions = value
                if let pane = helping, value.granted(pane) { helping = nil }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        helping = nil
    }

    /// Allow: the pane in System Settings, with the drag tile over it.
    public func allow(_ pane: ComputerUsePermissionPane) {
        guard let source, !permissions.granted(pane) else { return }
        source.openSettings(pane)
        helping = pane
    }

    /// The tile's close button.
    public func dismissHelper() {
        helping = nil
    }

    public var helperAppURL: URL? { source?.helperAppURL }
}
