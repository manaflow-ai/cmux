import Foundation
import IOSurface

final class SimulatorFramebufferPortFixtureDescriptor: NSObject {
    private var surface: IOSurface?
    private var frameCallback: (() -> Void)?
    private var propertiesChangedCallback: (() -> Void)?
    private let properties: NSObject & SimulatorFramebufferPortFixtureProperties
    private let propertiesAvailableAfterRegistration: Bool
    private var didRegisterCallbacks = false
    private(set) var screenPropertiesReadCount = 0

    init(
        screenID: UInt32 = 0,
        screenType: UInt64 = 0,
        width: Int = 8,
        height: Int = 12,
        propertiesAvailableAfterRegistration: Bool = false,
        usesDefaultScreenFlag: Bool = false,
        usesForwardingScreenProperties: Bool = false
    ) {
        surface = makeSimulatorFramebufferPortFixtureSurface(width: width, height: height)
        let concreteProperties: NSObject & SimulatorFramebufferPortFixtureProperties = if usesDefaultScreenFlag {
            SimulatorFramebufferPortFixtureDefaultScreenProperties(
                screenID: screenID,
                isDefault: screenType == 0
            )
        } else {
            SimulatorFramebufferPortFixtureScreenProperties(
                screenID: screenID,
                screenType: screenType
            )
        }
        properties = usesForwardingScreenProperties
            ? SimulatorFramebufferPortFixtureForwardingProperties(target: concreteProperties)
            : concreteProperties
        self.propertiesAvailableAfterRegistration = propertiesAvailableAfterRegistration
        super.init()
    }

    @objc dynamic func framebufferSurface() -> AnyObject? { surface }
    @objc dynamic func screenProperties() -> AnyObject? {
        screenPropertiesReadCount += 1
        if propertiesAvailableAfterRegistration, !didRegisterCallbacks { return nil }
        return properties
    }

    @objc(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
    dynamic func registerScreenCallbacks(
        uuid _: NSUUID,
        callbackQueue _: DispatchQueue,
        frameCallback: @escaping @convention(block) () -> Void,
        surfacesChangedCallback _: @escaping @convention(block) () -> Void,
        propertiesChangedCallback: @escaping @convention(block) () -> Void
    ) {
        didRegisterCallbacks = true
        self.frameCallback = frameCallback
        self.propertiesChangedCallback = propertiesChangedCallback
        propertiesChangedCallback()
    }

    @objc dynamic func unregisterScreenCallbacks(withUUID _: NSUUID) {
        frameCallback = nil
        propertiesChangedCallback = nil
    }

    func publishFrame(width: Int, height: Int) {
        surface = makeSimulatorFramebufferPortFixtureSurface(width: width, height: height)
        frameCallback?()
    }

    func removeSurface() {
        surface = nil
        frameCallback?()
    }

    func publishOrientation(_ rawValue: UInt32) {
        properties.orientation = rawValue
        propertiesChangedCallback?()
    }
}

final class SimulatorFramebufferPortFixtureScreenProperties: NSObject,
    SimulatorFramebufferPortFixtureProperties
{
    private let identifier: UInt32
    private let type: UInt64
    var orientation: UInt32 = 1

    init(screenID: UInt32, screenType: UInt64) {
        identifier = screenID
        type = screenType
    }

    @objc dynamic func screenID() -> UInt32 { identifier }
    @objc dynamic func screenType() -> UInt64 { type }
    @objc dynamic func uiOrientation() -> UInt32 { orientation }
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
