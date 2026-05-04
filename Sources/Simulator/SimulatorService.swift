import Foundation
import ObjectiveC

struct SimulatorDevice: Identifiable, Equatable, Hashable {
    enum State: String {
        case creating, shutdown, booting, booted, shuttingDown, unknown
    }

    let udid: String
    let name: String
    let state: State
    let runtime: String

    var id: String { udid }
    var isBooted: Bool { state == .booted }
}

enum SimulatorError: Error, LocalizedError {
    case frameworksUnavailable(String)
    case noServiceContext
    case noDeviceSet
    case notFound(udid: String)
    case bootFailed(String?)
    case shutdownFailed(String?)
    case ioUnavailable

    var errorDescription: String? {
        switch self {
        case .frameworksUnavailable(let msg): return "Private frameworks unavailable: \(msg)"
        case .noServiceContext: return "Could not get SimServiceContext"
        case .noDeviceSet: return "Could not resolve default SimDeviceSet"
        case .notFound(let udid): return "Simulator not found: \(udid)"
        case .bootFailed(let detail): return "Boot failed: \(detail ?? "unknown")"
        case .shutdownFailed(let detail): return "Shutdown failed: \(detail ?? "unknown")"
        case .ioUnavailable: return "Simulator IO client unavailable"
        }
    }
}

/// Wraps CoreSimulator's `SimServiceContext` / `SimDeviceSet` / `SimDevice`
/// via the Objective-C runtime. Single instance per app process.
final class SimulatorService: @unchecked Sendable {
    static let shared = SimulatorService()

    private init() {}

    func listDevices() throws -> [SimulatorDevice] {
        guard SimulatorPrivateFrameworks.ensureLoaded() else {
            throw SimulatorError.frameworksUnavailable(
                SimulatorPrivateFrameworks.loadErrorMessage ?? "unknown"
            )
        }
        guard let set = try resolveDefaultSet() else { throw SimulatorError.noDeviceSet }
        let devices = (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
        return devices.map { describe(device: $0) }
    }

    func boot(udid: String) throws {
        guard SimulatorPrivateFrameworks.ensureLoaded() else {
            throw SimulatorError.frameworksUnavailable(
                SimulatorPrivateFrameworks.loadErrorMessage ?? "unknown"
            )
        }
        guard let device = try resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }

        // Prefer bootWithOptions:error: with persist=true so the boot survives
        // disconnect of this process. Fall back to bootWithError:.
        let bootOpts = NSSelectorFromString("bootWithOptions:error:")
        if device.responds(to: bootOpts) {
            var err: NSError?
            let opts: NSDictionary = ["persist": true]
            if invokeBoolWithObjAndError(device, bootOpts, opts, &err) { return }
            if let err, !errorIsAlreadyBooted(err) {
                throw SimulatorError.bootFailed(err.localizedDescription)
            } else if err == nil {
                return
            }
        }

        let bootSel = NSSelectorFromString("bootWithError:")
        if device.responds(to: bootSel) {
            var err: NSError?
            if invokeBoolWithError(device, bootSel, &err) { return }
            if let err, !errorIsAlreadyBooted(err) {
                throw SimulatorError.bootFailed(err.localizedDescription)
            }
            return
        }
        throw SimulatorError.bootFailed("no boot selector")
    }

    func shutdown(udid: String) throws {
        guard SimulatorPrivateFrameworks.ensureLoaded() else {
            throw SimulatorError.frameworksUnavailable(
                SimulatorPrivateFrameworks.loadErrorMessage ?? "unknown"
            )
        }
        guard let device = try resolveDevice(udid: udid) else {
            throw SimulatorError.notFound(udid: udid)
        }
        let sel = NSSelectorFromString("shutdownWithError:")
        guard device.responds(to: sel) else {
            throw SimulatorError.shutdownFailed("no shutdown selector")
        }
        var err: NSError?
        if invokeBoolWithError(device, sel, &err) { return }
        if let err, !errorIsAlreadyShutdown(err) {
            throw SimulatorError.shutdownFailed(err.localizedDescription)
        }
    }

    /// Returns the underlying `SimDevice` ObjC object. Used by the screen
    /// adapter to register IOSurface callbacks.
    func resolveDevice(udid: String) throws -> NSObject? {
        guard let set = try resolveDefaultSet() else { return nil }
        let devices = (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
        for device in devices {
            if (device.value(forKey: "UDID") as? NSUUID)?.uuidString == udid {
                return device
            }
        }
        return nil
    }

    /// Logical device screen size in points, or nil if the SimDeviceType
    /// doesn't expose `mainScreenSize`. The HID dispatch path expects
    /// coordinates in points, so callers convert from pixel-space (the
    /// IOSurface) to point-space using this size.
    func deviceScreenSizeInPoints(udid: String) -> CGSize? {
        guard let device = try? resolveDevice(udid: udid) else { return nil }
        guard let dt = device.value(forKey: "deviceType") as? NSObject else { return nil }
        if let s = dt.value(forKey: "mainScreenSize") as? NSValue {
            let cg = s.sizeValue
            if cg.width > 0, cg.height > 0 { return cg }
        }
        // Some SimDeviceType variants expose the same data via `screenSize`
        // or `frontBufferSize`. Fall through gracefully.
        if let s = dt.value(forKey: "screenSize") as? NSValue {
            let cg = s.sizeValue
            if cg.width > 0, cg.height > 0 { return cg }
        }
        return nil
    }

    // MARK: - private

    private func resolveDefaultSet() throws -> NSObject? {
        guard let cls = NSClassFromString("SimServiceContext") else {
            throw SimulatorError.noServiceContext
        }
        let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        var err: NSError?
        guard let ctx = invokeClassObjWithObjAndError(
            cls,
            sel,
            SimulatorPrivateFrameworks.developerDir() as NSString,
            &err
        ) else {
            throw SimulatorError.noServiceContext
        }
        let setSel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard ctx.responds(to: setSel) else { return nil }
        var setErr: NSError?
        return invokeObjWithError(ctx, setSel, &setErr)
    }

    private func describe(device: NSObject) -> SimulatorDevice {
        let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? ""
        let name = (device.value(forKey: "name") as? String) ?? "Unknown"
        let raw = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? 1
        let runtimeName = (device.value(forKey: "runtime") as? NSObject).flatMap { rt -> String? in
            (rt.value(forKey: "name") as? String) ?? (rt.value(forKey: "versionString") as? String)
        } ?? ""
        return SimulatorDevice(
            udid: udid,
            name: name,
            state: state(from: raw),
            runtime: runtimeName
        )
    }

    private func state(from raw: UInt) -> SimulatorDevice.State {
        switch raw {
        case 0: return .creating
        case 1: return .shutdown
        case 2: return .booting
        case 3: return .booted
        case 4: return .shuttingDown
        default: return .unknown
        }
    }

    private func errorIsAlreadyBooted(_ err: NSError) -> Bool {
        let msg = err.localizedDescription.lowercased()
        return msg.contains("already booted") || msg.contains("currently booted")
    }

    private func errorIsAlreadyShutdown(_ err: NSError) -> Bool {
        let msg = err.localizedDescription.lowercased()
        return msg.contains("already") && msg.contains("shut")
    }
}

// MARK: - ObjC runtime invokers

@discardableResult
func invokeBoolWithError(_ target: NSObject, _ sel: Selector, _ err: inout NSError?) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    let fn = unsafeBitCast(imp, to: Fn.self)
    return withUnsafeMutablePointer(to: &err) { ptr in
        fn(target, sel, AutoreleasingUnsafeMutablePointer(ptr))
    }
}

@discardableResult
func invokeBoolWithObjAndError(
    _ target: NSObject,
    _ sel: Selector,
    _ obj: NSObject,
    _ err: inout NSError?
) -> Bool {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return false }
    typealias Fn = @convention(c) (
        AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    let fn = unsafeBitCast(imp, to: Fn.self)
    return withUnsafeMutablePointer(to: &err) { ptr in
        fn(target, sel, obj, AutoreleasingUnsafeMutablePointer(ptr))
    }
}

func invokeObjWithError(_ target: NSObject, _ sel: Selector, _ err: inout NSError?) -> NSObject? {
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
    let fn = unsafeBitCast(imp, to: Fn.self)
    let result: Unmanaged<AnyObject>? = withUnsafeMutablePointer(to: &err) { ptr in
        fn(target, sel, AutoreleasingUnsafeMutablePointer(ptr))
    }
    return result?.takeUnretainedValue() as? NSObject
}

func invokeClassObjWithObjAndError(
    _ cls: AnyClass,
    _ sel: Selector,
    _ obj: NSObject,
    _ err: inout NSError?
) -> NSObject? {
    let metaCls: AnyClass = object_getClass(cls) ?? cls
    guard let imp = class_getMethodImplementation(metaCls, sel) else { return nil }
    typealias Fn = @convention(c) (
        AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Unmanaged<AnyObject>?
    let fn = unsafeBitCast(imp, to: Fn.self)
    let result: Unmanaged<AnyObject>? = withUnsafeMutablePointer(to: &err) { ptr in
        fn(cls, sel, obj, AutoreleasingUnsafeMutablePointer(ptr))
    }
    return result?.takeUnretainedValue() as? NSObject
}
