import Foundation
import ObjectiveC.runtime

@MainActor
final class SimulatorDeviceResolver {
    private let developerDirectory: String

    init(developerDirectory: String) {
        self.developerDirectory = developerDirectory
    }

    func device(udid: String) throws -> NSObject {
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            throw SimulatorWorkerFailure.privateAPIUnavailable("SimServiceContext is unavailable.")
        }

        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let context = invokeClassObjectWithObjectAndError(
            contextClass,
            selector: contextSelector,
            argument: developerDirectory as NSString
        ) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "CoreSimulator could not create a service context for \(developerDirectory)."
            )
        }

        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let set = invokeObjectWithError(context, selector: setSelector) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable("CoreSimulator's default device set is unavailable.")
        }

        guard let devices = objectProperty(set, selectorName: "devices") as? [NSObject] else {
            throw SimulatorWorkerFailure.privateAPIUnavailable("CoreSimulator did not return its device list.")
        }

        guard let match = devices.first(where: { device in
            let identifier = objectProperty(device, selectorName: "UDID") as? NSUUID
            return identifier?.uuidString.caseInsensitiveCompare(udid) == .orderedSame
        }) else {
            throw SimulatorWorkerFailure.deviceNotFound("Simulator \(udid) is not installed in the active device set.")
        }
        return match
    }

    func requireBooted(_ device: NSObject) throws {
        let state = objectProperty(device, selectorName: "stateString") as? String ?? "Unknown"
        guard state == "Booted" else {
            throw SimulatorWorkerFailure.deviceNotBooted("Simulator is \(state), not Booted.")
        }
    }
}

func objectProperty(_ target: NSObject, selectorName: String) -> AnyObject? {
    let selector = NSSelectorFromString(selectorName)
    guard target.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: target), selector)
    else {
        return nil
    }
    typealias Function = @convention(c) (AnyObject, Selector) -> AnyObject?
    return unsafeBitCast(implementation, to: Function.self)(target, selector)
}

func invokeObjectWithError(_ target: NSObject, selector: Selector) -> NSObject? {
    guard target.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: target), selector)
    else {
        return nil
    }
    typealias Function = @convention(c) (
        AnyObject,
        Selector,
        AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    var error: NSError?
    return unsafeBitCast(implementation, to: Function.self)(target, selector, &error) as? NSObject
}

func invokeClassObjectWithObjectAndError(
    _ targetClass: AnyClass,
    selector: Selector,
    argument: AnyObject
) -> NSObject? {
    guard let metaClass = object_getClass(targetClass),
          let implementation = class_getMethodImplementation(metaClass, selector)
    else {
        return nil
    }
    typealias Function = @convention(c) (
        AnyClass,
        Selector,
        AnyObject,
        AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> AnyObject?
    var error: NSError?
    return unsafeBitCast(implementation, to: Function.self)(targetClass, selector, argument, &error) as? NSObject
}
