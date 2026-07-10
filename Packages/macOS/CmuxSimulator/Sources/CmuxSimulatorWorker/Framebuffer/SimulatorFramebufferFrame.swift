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

    init(surface: IOSurface) {
        self.surface = surface
        width = IOSurfaceGetWidth(surface)
        height = IOSurfaceGetHeight(surface)
    }
}
