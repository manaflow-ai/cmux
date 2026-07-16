import Foundation
import IOSurface

final class SimulatorFramebufferPortFixtureDescriptor: NSObject {
    private var surface: IOSurface?
    private var frameCallback: (() -> Void)?
    private let properties: SimulatorFramebufferPortFixtureScreenProperties

    init(screenID: UInt32 = 0, width: Int = 8, height: Int = 12) {
        surface = makeSimulatorFramebufferPortFixtureSurface(width: width, height: height)
        properties = SimulatorFramebufferPortFixtureScreenProperties(screenID: screenID)
        super.init()
    }

    @objc dynamic func framebufferSurface() -> AnyObject? { surface }
    @objc dynamic func screenProperties() -> AnyObject { properties }

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

    func removeSurface() {
        surface = nil
        frameCallback?()
    }
}

final class SimulatorFramebufferPortFixtureScreenProperties: NSObject {
    private let identifier: UInt32

    init(screenID: UInt32) {
        identifier = screenID
    }

    @objc dynamic func screenID() -> UInt32 { identifier }
    @objc dynamic func uiOrientation() -> UInt32 { 1 }
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
