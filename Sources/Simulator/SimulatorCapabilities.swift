import Foundation
import ObjectiveC

/// Up-front probe of every CoreSimulator + SimulatorKit symbol, class,
/// and selector cmux's simulator viewer relies on. Designed so that a
/// future macOS / Xcode update which renames or removes a private API
/// surfaces as an "unavailable" status with a precise reason instead
/// of a hard crash inside `unsafeBitCast`'d C calls.
///
/// Cached: the first probe sets the result; subsequent calls return it.
enum SimulatorCapabilityStatus {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reasonText: String? {
        if case .unavailable(let r) = self { return r }
        return nil
    }
}

struct SimulatorCapabilityReport {
    let listing: SimulatorCapabilityStatus
    let lifecycle: SimulatorCapabilityStatus
    let screen: SimulatorCapabilityStatus
    let input: SimulatorCapabilityStatus
    let xcodeVersion: String?

    /// Single-line summary, useful for a status banner.
    var summary: String {
        if listing.isAvailable, lifecycle.isAvailable, screen.isAvailable, input.isAvailable {
            return "All simulator features available."
        }
        var parts: [String] = []
        if let r = listing.reasonText  { parts.append("listing: \(r)") }
        if let r = lifecycle.reasonText { parts.append("boot/shutdown: \(r)") }
        if let r = screen.reasonText   { parts.append("screen mirror: \(r)") }
        if let r = input.reasonText    { parts.append("touch input: \(r)") }
        return parts.joined(separator: "  ·  ")
    }
}

enum SimulatorCapabilities {
    private static let lock = NSLock()
    private static var cachedReport: SimulatorCapabilityReport?

    /// Minimum Xcode major version the preview-kit IndigoHID recipe is
    /// known to work with. Bumped here when verified against newer Xcodes.
    static let minimumXcodeMajor: Int = 26

    /// HID client class lookup order. Apple's Swift mangling can change
    /// across Xcode versions, so we try the known canonical name first
    /// then fall through to ObjC-shaped fallbacks before scanning the
    /// runtime as a last resort.
    static let hidClientClassCandidates: [String] = [
        "_TtC12SimulatorKit24SimDeviceLegacyHIDClient",
        "SimDeviceLegacyHIDClient",
        "SimDeviceHIDClient",
    ]

    static func report() -> SimulatorCapabilityReport {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedReport { return cached }

        let xcode = currentXcodeVersionString()

        if !SimulatorPrivateFrameworks.ensureLoaded() {
            let reason = SimulatorPrivateFrameworks.loadErrorMessage ?? "frameworks not loaded"
            let r = SimulatorCapabilityReport(
                listing: .unavailable(reason: reason),
                lifecycle: .unavailable(reason: reason),
                screen: .unavailable(reason: reason),
                input: .unavailable(reason: reason),
                xcodeVersion: xcode
            )
            cachedReport = r
            return r
        }

        if let xcMajor = xcode.flatMap(parseMajorVersion), xcMajor < minimumXcodeMajor {
            let reason = "needs Xcode \(minimumXcodeMajor)+ (have \(xcode ?? "?"))"
            let r = SimulatorCapabilityReport(
                listing: probeListing(),                    // listing/lifecycle work on older Xcodes
                lifecycle: probeLifecycle(),
                screen: .unavailable(reason: reason),       // preview-kit screen path is Xcode 26+
                input: .unavailable(reason: reason),        // preview-kit HID is Xcode 26+
                xcodeVersion: xcode
            )
            cachedReport = r
            return r
        }

        let r = SimulatorCapabilityReport(
            listing: probeListing(),
            lifecycle: probeLifecycle(),
            screen: probeScreen(),
            input: probeInput(),
            xcodeVersion: xcode
        )
        cachedReport = r
        return r
    }

    /// Exposed for tests / re-probe after Xcode swap. Cheap.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        cachedReport = nil
    }

    // MARK: - probes

    private static func probeListing() -> SimulatorCapabilityStatus {
        guard NSClassFromString("SimServiceContext") != nil else {
            return .unavailable(reason: "SimServiceContext class missing")
        }
        let metaSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let cls = NSClassFromString("SimServiceContext"),
              let meta = object_getClass(cls),
              class_getMethodImplementation(meta, metaSel) != nil else {
            return .unavailable(reason: "sharedServiceContextForDeveloperDir:error: missing")
        }
        return .available
    }

    private static func probeLifecycle() -> SimulatorCapabilityStatus {
        // bootWithError: is the older signature; bootWithOptions:error: is preferred
        // on newer Xcodes. We accept either.
        guard let cls = NSClassFromString("SimDevice") else {
            return .unavailable(reason: "SimDevice class missing")
        }
        let bootOpts = NSSelectorFromString("bootWithOptions:error:")
        let bootPlain = NSSelectorFromString("bootWithError:")
        let shutdown = NSSelectorFromString("shutdownWithError:")
        let hasBoot = class_getInstanceMethod(cls, bootOpts) != nil
            || class_getInstanceMethod(cls, bootPlain) != nil
        let hasShutdown = class_getInstanceMethod(cls, shutdown) != nil
        if !hasBoot { return .unavailable(reason: "no boot selector on SimDevice") }
        if !hasShutdown { return .unavailable(reason: "no shutdown selector on SimDevice") }
        return .available
    }

    private static func probeScreen() -> SimulatorCapabilityStatus {
        // Only check things that apply uniformly across simulators. The
        // per-port descriptor is enumerated dynamically at attach time,
        // so we skip it here to avoid false negatives when no device is
        // booted.
        guard let cls = NSClassFromString("SimDevice") else {
            return .unavailable(reason: "SimDevice class missing")
        }
        guard class_getInstanceMethod(cls, NSSelectorFromString("io")) != nil else {
            return .unavailable(reason: "SimDevice has no -io accessor")
        }
        return .available
    }

    private static func probeInput() -> SimulatorCapabilityStatus {
        if resolveHIDClientClass() == nil {
            return .unavailable(reason: "no SimDeviceLegacyHIDClient class")
        }
        // RTLD_DEFAULT after our dlopen of SimulatorKit; symbols should be visible.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        if dlsym(handle, "IndigoHIDMessageForMouseNSEvent") == nil {
            return .unavailable(reason: "IndigoHIDMessageForMouseNSEvent missing")
        }
        // Service warmup symbols are non-fatal but worth flagging.
        if dlsym(handle, "IndigoHIDMessageToCreatePointerService") == nil {
            return .unavailable(reason: "IndigoHIDMessageToCreatePointerService missing (preview-kit not present?)")
        }
        return .available
    }

    /// Public so `IndigoHIDInput` doesn't have to duplicate the lookup.
    static func resolveHIDClientClass() -> AnyClass? {
        for name in hidClientClassCandidates {
            if let cls = NSClassFromString(name) { return cls }
        }
        // Last resort: scan the runtime for a class whose name contains
        // "HIDClient" and which responds to initWithDevice:error:. This
        // catches future Swift mangling changes within SimulatorKit.
        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return nil }
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let allClasses = AutoreleasingUnsafeMutablePointer<AnyClass>(buffer)
        let n = objc_getClassList(allClasses, count)
        let initSel = NSSelectorFromString("initWithDevice:error:")
        for i in 0..<Int(n) {
            let cls: AnyClass = buffer[i]
            let name = String(cString: class_getName(cls))
            guard name.contains("HIDClient") else { continue }
            if class_getInstanceMethod(cls, initSel) != nil {
                return cls
            }
        }
        return nil
    }

    // MARK: - Xcode version

    private static func currentXcodeVersionString() -> String? {
        let dev = SimulatorPrivateFrameworks.developerDir()
        // Xcode.app/Contents/Developer -> Xcode.app/Contents/version.plist
        let url = URL(fileURLWithPath: dev)
            .deletingLastPathComponent()
            .appendingPathComponent("version.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }
        return (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
    }

    private static func parseMajorVersion(_ s: String) -> Int? {
        Int(s.split(separator: ".").first.map(String.init) ?? "")
    }
}
