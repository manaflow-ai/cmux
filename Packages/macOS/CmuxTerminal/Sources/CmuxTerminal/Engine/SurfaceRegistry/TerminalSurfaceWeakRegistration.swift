import CmuxTerminalCore
import Foundation

/// Weak identity and focus metadata for one registered terminal surface.
final class TerminalSurfaceWeakRegistration {
    weak var surface: (any TerminalSurfacing)?
    let objectId: ObjectIdentifier
    let surfaceId: UUID
    let sequence: UInt64
    var focusPlacement: TerminalSurfaceFocusPlacement
    var previousSweepObjectId: ObjectIdentifier
    var nextSweepObjectId: ObjectIdentifier

    init(surface: any TerminalSurfacing, sequence: UInt64) {
        self.surface = surface
        self.objectId = ObjectIdentifier(surface)
        self.surfaceId = surface.id
        self.sequence = sequence
        self.focusPlacement = surface.focusPlacement
        self.previousSweepObjectId = objectId
        self.nextSweepObjectId = objectId
    }
}
