import Foundation

@MainActor
final class SimulatorHostWindowVisibilityCoordinator {
    let observerID = UUID()
    var onRemoval: ((UUID) -> Void)?
    private var wasRemoved = false

    func remove() {
        guard !wasRemoved else { return }
        wasRemoved = true
        onRemoval?(observerID)
        onRemoval = nil
    }
}
