import CmuxSimulator
import IOSurface

/// One retained private Simulator surface handed to the bounded frame copier.
///
/// SAFETY: IOSurface storage is reference-counted and process-shareable. The
/// publisher only reads this surface, and its single consumer owns every write
/// to the destination ring.
struct SimulatorFramebufferFrame: @unchecked Sendable {
    let surface: IOSurface
    let width: Int
    let height: Int
    let geometry: SimulatorSurfaceGeometry?

    init(surface: IOSurface, geometry: SimulatorSurfaceGeometry? = nil) {
        self.surface = surface
        self.geometry = geometry
        let size = SimulatorFramebufferTargetSize(
            sourceWidth: IOSurfaceGetWidth(surface),
            sourceHeight: IOSurfaceGetHeight(surface),
            geometry: geometry
        )
        width = size.width
        height = size.height
    }
}
