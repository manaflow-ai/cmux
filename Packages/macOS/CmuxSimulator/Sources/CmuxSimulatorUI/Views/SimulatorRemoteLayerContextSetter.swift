import CmuxSimulatorObjC
import QuartzCore

struct SimulatorRemoteLayerContextSetter {
    func set(contextID: UInt32, on layer: CALayer) -> Bool {
        CmuxSimulatorSetRemoteLayerContext(layer, contextID)
    }
}
