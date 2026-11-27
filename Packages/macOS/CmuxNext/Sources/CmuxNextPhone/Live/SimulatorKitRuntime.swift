import Darwin
import Foundation
import ObjectiveC.runtime

/// The active Xcode's private CoreSimulator and SimulatorKit, loaded with
/// `dlopen` at first use so the cmux binary links nothing version-specific.
/// Loading is the one thing that can fail per Mac (no Xcode, a changed
/// Xcode); the phone tab then falls back to still frames from `simctl`.
@MainActor
final class SimulatorKitRuntime {
    let developerDirectory: String
    private(set) var simulatorKit: UnsafeMutableRawPointer?
    private var deviceSet: NSObject?

    /// - Parameter developerDirectory: `xcode-select -p` (…/Xcode.app/Contents/Developer).
    init(developerDirectory: String) {
        self.developerDirectory = developerDirectory
    }

    /// Loads both frameworks; throws when this Xcode lacks them.
    func load() throws {
        guard simulatorKit == nil else { return }
        let core = ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
                    "\(developerDirectory)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"]
        guard Self.open(core) != nil else { throw PhoneError.missingTool(.xcode) }
        // SimulatorKit moved to Contents/SharedFrameworks in Xcode 27.
        let kit = ["\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
                   "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"]
        guard let handle = Self.open(kit) else { throw PhoneError.unsupported(mode: .simulator, what: "live screens with this Xcode") }
        simulatorKit = handle
    }

    /// A symbol from SimulatorKit, else from anything already loaded.
    func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        if let simulatorKit, let found = dlsym(simulatorKit, name) { return found }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    /// The `SimDevice` for `udid` in the default device set.
    func device(_ udid: String) throws -> NSObject {
        try load()
        let set = try defaultDeviceSet()
        let devices = privateObject(set, "devices") as? [NSObject] ?? []
        guard let device = devices.first(where: {
            (privateObject($0, "UDID") as? NSUUID)?.uuidString.caseInsensitiveCompare(udid) == .orderedSame
        }) else { throw PhoneError.unknownDevice("sim:\(udid)") }
        guard (privateObject(device, "stateString") as? String) == "Booted" else { throw PhoneError.notRunning("sim:\(udid)") }
        return device
    }

    private func defaultDeviceSet() throws -> NSObject {
        if let deviceSet { return deviceSet }
        let selector = privateSelector("sharedServiceContextForDeveloperDir:error:")
        guard let contextClass = NSClassFromString("SimServiceContext"), let meta = object_getClass(contextClass),
              class_respondsToSelector(meta, selector), let imp = class_getMethodImplementation(meta, selector) else {
            throw PhoneError.unsupported(mode: .simulator, what: "live screens with this Xcode")
        }
        typealias Function = @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<AnyObject>?
        var error: NSError?
        guard let context = unsafeBitCast(imp, to: Function.self)(contextClass, selector, developerDirectory as NSString, &error)?
            .takeUnretainedValue() as? NSObject,
            let set = privateObjectWithError(context, "defaultDeviceSetWithError:") else {
            throw PhoneError.unsupported(mode: .simulator, what: "live screens with this Xcode")
        }
        deviceSet = set
        return set
    }

    private static func open(_ paths: [String]) -> UnsafeMutableRawPointer? {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            // concurrency-allow: KNOWN one-time main-thread stall (SimulatorKitHID is @MainActor): maps Xcode's CoreSimulator/SimulatorKit at the first live simulator screen of a process, not at launch; moving it off main is a follow-up
            if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) { return handle }
        }
        return nil
    }
}
