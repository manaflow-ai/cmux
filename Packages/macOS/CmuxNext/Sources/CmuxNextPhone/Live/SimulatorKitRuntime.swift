import Darwin
import Foundation

/// The active Xcode's private CoreSimulator and SimulatorKit, loaded with
/// `dlopen` at first use so the cmux binary links nothing version-specific.
/// Loading is the one thing that can fail per Mac (no Xcode, a changed
/// Xcode); the phone tab then falls back to still frames from `simctl`.
@MainActor
final class SimulatorKitRuntime {
    let developerDirectory: String
    /// Both frameworks are loaded (`RTLD_GLOBAL`, never closed), so their symbols resolve.
    private(set) var isLoaded = false
    private var deviceSet: NSObject?

    /// - Parameter developerDirectory: `xcode-select -p` (…/Xcode.app/Contents/Developer).
    init(developerDirectory: String) {
        self.developerDirectory = developerDirectory
    }

    /// Loads both frameworks; throws when this Xcode lacks them.
    func load() throws {
        guard !isLoaded else { return }
        let core = ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
                    "\(developerDirectory)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"]
        guard Self.open(core) else { throw PhoneError.missingTool(.xcode) }
        // SimulatorKit moved to Contents/SharedFrameworks in Xcode 27.
        let kit = ["\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
                   "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"]
        guard Self.open(kit) else { throw PhoneError.unsupported(mode: .simulator, what: "live screens with this Xcode") }
        isLoaded = true
    }

    /// The exported C function `name` as `F`, its prototype spelled as a
    /// `@convention(c)` type: SimulatorKit's (opened `RTLD_GLOBAL`, so the
    /// default search finds it) or one already loaded (libxpc's `_4sim` calls).
    func function<F>(_ name: String, as _: F.Type) -> F? {
        // SAFETY: RTLD_DEFAULT (-2; Swift does not import the macro) searches every loaded image;
        // a non-nil result is the address of the exported function `name`, whose image is never
        // closed. The pointer is only converted, never read or written.
        guard let address = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        // SAFETY: as above, the address of the C function `name`; each caller spells F from that
        // function's prototype (SimulatorKit's IndigoHIDMessageFor* builders, as classic cmux and
        // idb's FBSimulatorIndigoHID call them; libxpc's _4sim calls), so the cast changes no
        // argument or return layout. F and the address are both one pointer.
        return unsafe unsafeBitCast(address, to: F.self)
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
        guard let contextClass = NSClassFromString("SimServiceContext"),
              let context = privateClassObjectWithError(contextClass, "sharedServiceContextForDeveloperDir:error:",
                                                        developerDirectory as NSString),
              let set = privateObjectWithError(context, "defaultDeviceSetWithError:") else {
            throw PhoneError.unsupported(mode: .simulator, what: "live screens with this Xcode")
        }
        deviceSet = set
        return set
    }

    /// Opens the first of `paths` that exists and loads; the library stays loaded for the
    /// life of the process (its classes and functions stay in use), so no handle is kept.
    private static func open(_ paths: [String]) -> Bool {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            // SAFETY: the path is a NUL-terminated copy Swift keeps alive for the call; the
            // returned handle is only compared with nil, never used.
            if unsafe dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil { return true }
        }
        return false
    }
}
