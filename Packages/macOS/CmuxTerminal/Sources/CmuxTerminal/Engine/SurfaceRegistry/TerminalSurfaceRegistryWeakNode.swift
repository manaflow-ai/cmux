import CmuxTerminalCore
import Foundation

final class TerminalSurfaceRegistryWeakNode {
    let identity: ObjectIdentifier
    weak var surface: (any TerminalSurfacing)?
    /// Process generation admitted for this particular surface registration.
    var terminalLifecycleID: UUID
    weak var previous: TerminalSurfaceRegistryWeakNode?
    var next: TerminalSurfaceRegistryWeakNode?
    var isRegistered = true

    init(
        surface: any TerminalSurfacing,
        terminalLifecycleID: UUID,
        next: TerminalSurfaceRegistryWeakNode?
    ) {
        identity = ObjectIdentifier(surface)
        self.surface = surface
        self.terminalLifecycleID = terminalLifecycleID
        self.next = next
    }
}
