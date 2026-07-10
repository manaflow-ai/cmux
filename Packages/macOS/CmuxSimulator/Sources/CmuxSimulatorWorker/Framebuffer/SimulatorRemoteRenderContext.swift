import CmuxSimulator
import QuartzCore

/// Worker-side Core Animation context whose integer identifier is safe to
/// hand back to cmux. The private object remains isolated in this process.
@MainActor
final class SimulatorRemoteRenderContext {
    let contextIdentifier: UInt32
    let rootLayer: CALayer

    private let context: NSObject

    init() throws {
        guard let contextClass = NSClassFromString("CAContext") as? NSObject.Type else {
            throw SimulatorWorkerFailure.privateAPIUnavailable("CAContext is unavailable.")
        }
        let selector = NSSelectorFromString("remoteContextWithOptions:")
        guard contextClass.responds(to: selector),
              let unmanaged = contextClass.perform(selector, with: [:] as NSDictionary),
              let context = unmanaged.takeUnretainedValue() as? NSObject,
              let identifier = simulatorRemoteContextIdentifier(of: context)
        else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "Core Animation remote contexts are unavailable on this macOS version."
            )
        }

        let rootLayer = CALayer()
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        rootLayer.masksToBounds = true

        let setLayerSelector = NSSelectorFromString("setLayer:")
        guard context.responds(to: setLayerSelector) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable("CAContext cannot host a remote layer.")
        }
        context.perform(setLayerSelector, with: rootLayer)

        self.context = context
        contextIdentifier = identifier
        self.rootLayer = rootLayer
        CATransaction.flush()
    }

    func resize(_ geometry: SimulatorSurfaceGeometry) {
        guard geometry.width.isFinite, geometry.height.isFinite,
              geometry.width > 0, geometry.height > 0
        else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        rootLayer.position = CGPoint(x: geometry.width / 2, y: geometry.height / 2)
        rootLayer.contentsScale = max(geometry.scale, 1)
        CATransaction.commit()
        CATransaction.flush()
    }

}

private func simulatorRemoteContextIdentifier(of context: NSObject) -> UInt32? {
    let selector = NSSelectorFromString("contextId")
    guard context.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: context), selector)
    else {
        return nil
    }
    typealias Function = @convention(c) (AnyObject, Selector) -> UInt32
    return unsafeBitCast(implementation, to: Function.self)(context, selector)
}
