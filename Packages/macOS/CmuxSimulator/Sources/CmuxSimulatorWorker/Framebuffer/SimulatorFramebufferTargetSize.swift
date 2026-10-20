import CmuxSimulator
import Foundation

struct SimulatorFramebufferTargetSize: Equatable, Sendable {
    let width: Int
    let height: Int

    init(sourceWidth: Int, sourceHeight: Int, geometry: SimulatorSurfaceGeometry?) {
        guard sourceWidth > 0, sourceHeight > 0,
              let geometry,
              geometry.width.isFinite, geometry.height.isFinite, geometry.scale.isFinite,
              geometry.width > 0, geometry.height > 0, geometry.scale > 0 else {
            width = sourceWidth
            height = sourceHeight
            return
        }
        let maximumWidth = geometry.width * geometry.scale
        let maximumHeight = geometry.height * geometry.scale
        let scale = min(
            1,
            maximumWidth / Double(sourceWidth),
            maximumHeight / Double(sourceHeight)
        )
        width = max(1, Int((Double(sourceWidth) * scale).rounded(.down)))
        height = max(1, Int((Double(sourceHeight) * scale).rounded(.down)))
    }
}
