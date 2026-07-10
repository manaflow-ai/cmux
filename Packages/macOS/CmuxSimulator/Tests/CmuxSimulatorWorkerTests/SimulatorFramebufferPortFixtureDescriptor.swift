import Foundation
import IOSurface

final class SimulatorFramebufferPortFixtureDescriptor: NSObject {
    private var surface: IOSurface
    private var frameCallback: (() -> Void)?

    override init() {
        surface = makeSimulatorFramebufferPortFixtureSurface(width: 8, height: 12)
        super.init()
    }

    @objc dynamic func framebufferSurface() -> AnyObject { surface }

    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    dynamic func registerScreenCallbacks(
        uuid _: NSUUID,
        callbackQueue _: DispatchQueue,
        frameCallback: @escaping @convention(block) () -> Void,
        surfacesChangedCallback _: @escaping @convention(block) () -> Void,
        propertiesChangedCallback: @escaping @convention(block) () -> Void
    ) {
        self.frameCallback = frameCallback
        propertiesChangedCallback()
    }

    @objc dynamic func unregisterScreenCallbacks(withUUID _: NSUUID) {
        frameCallback = nil
    }

    func publishFrame(width: Int, height: Int) {
        surface = makeSimulatorFramebufferPortFixtureSurface(width: width, height: height)
        frameCallback?()
    }
}

private func makeSimulatorFramebufferPortFixtureSurface(width: Int, height: Int) -> IOSurface {
    let bytesPerRow = width * 4
    return IOSurfaceCreate([
        kIOSurfaceWidth: width,
        kIOSurfaceHeight: height,
        kIOSurfaceBytesPerElement: 4,
        kIOSurfaceBytesPerRow: bytesPerRow,
        kIOSurfaceAllocSize: bytesPerRow * height,
        kIOSurfacePixelFormat: UInt32(0x4247_5241),
    ] as CFDictionary)!
}
