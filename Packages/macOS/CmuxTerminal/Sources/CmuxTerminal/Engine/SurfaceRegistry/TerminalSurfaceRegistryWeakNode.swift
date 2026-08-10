import CmuxTerminalCore
import Foundation

final class TerminalSurfaceRegistryWeakNode {
    let identity: ObjectIdentifier
    weak var surface: (any TerminalSurfacing)?
    weak var previous: TerminalSurfaceRegistryWeakNode?
    var next: TerminalSurfaceRegistryWeakNode?
    var isRegistered = true

    init(
        surface: any TerminalSurfacing,
        next: TerminalSurfaceRegistryWeakNode?
    ) {
        identity = ObjectIdentifier(surface)
        self.surface = surface
        self.next = next
    }
}
