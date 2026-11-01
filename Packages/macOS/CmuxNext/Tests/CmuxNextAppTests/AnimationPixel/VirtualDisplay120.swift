import AppKit
import CoreGraphics
import ObjectiveC

/// A 120 Hz display made inside the test process, so an animation test draws at the rate of a
/// person's ProMotion screen whatever screen the mini's console session has (often a 60 Hz VNC
/// one). CoreGraphics' private `CGVirtualDisplay`, the API of scripts/ci/frame-pacing/vdisplay.m
/// (BetterDisplay and DeskPad use it too); the display goes away with this object. `scale` 1 makes
/// a 1x display, 2 a HiDPI one.
///
/// Every failure throws, with what failed: an animation pixel test on a display step fails without
/// its display, it never skips (cmux-ad 2026-11-01, rule 5).
@MainActor
final class VirtualDisplay120 {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let hz: Double = 120

    /// The CoreGraphics displays of this process, by scale, made together on first use and kept
    /// (never dropped, also when a check fails) until the process exits. AppKit reads its screen
    /// list once in a test process and then does not see a later display (red5 83b25c26: CoreGraphics
    /// online [201], AppKit screens [199]): so both scales are made before anything reads it.
    private static var made: [Int: (id: CGDirectDisplayID, display: AnyObject)] = [:]
    private static var ready: [Int: VirtualDisplay120] = [:]

    /// The process's `scale`x display (1 or 2), listed by AppKit and ticking at 120 Hz.
    static func shared(scale: Int) async throws -> VirtualDisplay120 {
        if let display = ready[scale] { return display }
        if made.isEmpty {
            for each in [1, 2] { made[each] = try makeDisplay(points: CGSize(width: 1600, height: 1000), scale: each) }
        }
        guard let entry = made[scale] else { throw Failure(description: "no \(scale)x virtual display (only 1x and 2x are made)") }
        let display = try await VirtualDisplay120(id: entry.id, display: entry.display, scale: scale)
        ready[scale] = display
        return display
    }

    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let scale: CGFloat
    /// The display's refresh period in seconds, measured from its own display link.
    let refreshPeriod: Double
    /// The display exists while this reference does.
    private let display: AnyObject

    /// Makes a CoreGraphics virtual display; reads nothing of AppKit.
    private static func makeDisplay(points: CGSize, scale: Int) throws -> (id: CGDirectDisplayID, display: AnyObject) {
        guard let descriptorType = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsType = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeType = NSClassFromString("CGVirtualDisplayMode"),
              let displayType = NSClassFromString("CGVirtualDisplay") else {
            throw Failure(description: "CGVirtualDisplay is not in this macOS")
        }
        let width = UInt32(points.width), height = UInt32(points.height), factor = UInt32(scale)
        let descriptor = descriptorType.init()
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        descriptor.setValue("cmux animation-pixel \(scale)x", forKey: "name")
        descriptor.setValue(NSNumber(value: width * factor), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: height * factor), forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 600, height: 600 * points.height / points.width)), forKey: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: UInt32(0x6370)), forKey: "productID")
        descriptor.setValue(NSNumber(value: UInt32(0x6370 + scale)), forKey: "vendorID")
        // A new serial each time: macOS keeps per-display settings by serial.
        descriptor.setValue(NSNumber(value: UInt32.random(in: 1...UInt32.max)), forKey: "serialNum")
        guard let made = Self.make(displayType, initializer: "initWithDescriptor:", argument: descriptor) else {
            throw Failure(description: "CGVirtualDisplay initWithDescriptor: gave nil (no window server session?)")
        }
        // A HiDPI display's mode is its size in PIXELS; macOS offers it at half that in points (2x).
        // A mode in points made the "2x" display 1x (green6 8a83669d: "virtual display 122 is 1.0x, not 2x").
        guard let mode = Self.makeMode(modeType, width: width * factor, height: height * factor, hz: Self.hz) else {
            throw Failure(description: "CGVirtualDisplayMode initWithWidth:height:refreshRate: gave nil")
        }
        let settings = settingsType.init()
        settings.setValue([mode], forKey: "modes")
        settings.setValue(NSNumber(value: UInt32(scale > 1 ? 1 : 0)), forKey: "hiDPI")
        guard Self.apply(settings, to: made) else { throw Failure(description: "CGVirtualDisplay applySettings: failed") }
        guard let number = (made as? NSObject)?.value(forKey: "displayID") as? NSNumber else {
            throw Failure(description: "CGVirtualDisplay has no displayID")
        }
        return (number.uint32Value, made)
    }

    /// Waits until AppKit lists display `id` at `scale` (running the main run loop and handing on
    /// AppKit's events meanwhile, as vdisplay.m does: AppKit learns of a new display there), then
    /// measures its refresh, again up to 3 times while it settles.
    private init(id: CGDirectDisplayID, display: AnyObject, scale: Int) async throws {
        displayID = id
        self.display = display
        self.scale = CGFloat(scale)
        var listed: NSScreen?
        for _ in 0..<100 {
            listed = NSScreen.screens.first { Self.number(of: $0) == id }
            if let found = listed, found.backingScaleFactor == CGFloat(scale) { break }
            Self.pumpEvents(for: 0.05)
            await Task.yield()
        }
        guard let first = listed else {
            var online = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
            CGGetOnlineDisplayList(16, &online, &count)
            let screens = NSScreen.screens.compactMap(Self.number(of:))
            throw Failure(description: "AppKit did not list virtual display \(id) within 5 s (CoreGraphics online: \(online.prefix(Int(count))), AppKit screens: \(screens))")
        }
        // A HiDPI virtual display comes up at 1x; its 2x mode (pixels twice its points) must be chosen
        // (green7b 354968770: "virtual display 6 is 1.0x, not 2x" with the mode given in pixels).
        var shown = first
        if scale > 1, shown.backingScaleFactor != CGFloat(scale) {
            try Self.chooseHiDPIMode(id, scale: scale)
            for _ in 0..<100 {
                if let again = NSScreen.screens.first(where: { Self.number(of: $0) == id }), again.backingScaleFactor == CGFloat(scale) {
                    shown = again
                    break
                }
                Self.pumpEvents(for: 0.05)
                await Task.yield()
            }
        }
        guard shown.backingScaleFactor == CGFloat(scale) else {
            throw Failure(description: "virtual display \(id) is \(shown.backingScaleFactor)x, not \(scale)x after choosing its \(scale)x mode")
        }
        screen = shown
        var periods: [Double] = []
        for _ in 0..<3 {
            let period = try await Self.measurePeriod(shown)
            periods.append(period)
            if abs(period - 1 / Self.hz) < 0.0005 { break }
        }
        refreshPeriod = periods.last ?? 0
        guard abs(refreshPeriod - 1 / Self.hz) < 0.0005 else {
            throw Failure(description: "virtual display \(id) ticks every \(periods.map { String(format: "%.2f", $0 * 1000) }) ms, not \(1000 / Self.hz) ms")
        }
    }

    /// Sets display `id` to its mode whose pixels are `scale` times its points (the HiDPI one), for
    /// this process only (kCGConfigureForAppOnly, as vdisplay.m's `main`).
    private static func chooseHiDPIMode(_ id: CGDirectDisplayID, scale: Int) throws {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let mode = modes.filter({ $0.pixelWidth == $0.width * scale && $0.pixelHeight == $0.height * scale })
            .max(by: { $0.width < $1.width }) else {
            throw Failure(description: "virtual display \(id) offers no \(scale)x mode: "
                + modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator: ", "))
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw Failure(description: "cannot begin a display configuration for \(id)")
        }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard result == .success else { throw Failure(description: "cannot set virtual display \(id) to its \(scale)x mode (\(result.rawValue))") }
    }

    /// Runs the main run loop and hands AppKit's queued events on for `seconds`.
    static func pumpEvents(for seconds: Double) {
        _ = NSApplication.shared
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    static func number(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The median display-link interval of `screen` over 0.6 s.
    private static func measurePeriod(_ screen: NSScreen) async throws -> Double {
        let probe = LinkProbe()
        // concurrency-allow: a test's own display link, invalidated below
        let link = screen.displayLink(target: probe, selector: #selector(LinkProbe.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        try await Task.sleep(for: .milliseconds(600))
        link.invalidate()
        let intervals = zip(probe.times.dropFirst(), probe.times).map { $0 - $1 }.sorted()
        guard intervals.count >= 10 else {
            throw Failure(description: "virtual display gave \(probe.times.count) display-link ticks in 0.6 s")
        }
        return intervals[intervals.count / 2]
    }

    private final class LinkProbe: NSObject {
        var times: [Double] = []
        @objc func tick(_ link: CADisplayLink) { times.append(link.timestamp) }
    }

    // MARK: Objective-C calls with scalar arguments (no header for the private classes)

    private static func allocate(_ type: AnyClass) -> AnyObject? {
        let selector = NSSelectorFromString("alloc")
        guard let method = class_getClassMethod(type, selector) else { return nil }
        typealias Alloc = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        // +1 from alloc; the initializer below consumes it.
        return unsafeBitCast(method_getImplementation(method), to: Alloc.self)(type as AnyObject, selector)?.takeUnretainedValue()
    }

    private static func make(_ type: AnyClass, initializer: String, argument: AnyObject) -> AnyObject? {
        guard let allocated = allocate(type) else { return nil }
        let selector = NSSelectorFromString(initializer)
        guard let method = class_getInstanceMethod(type, selector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Init.self)(allocated, selector, argument)?.takeRetainedValue()
    }

    private static func makeMode(_ type: AnyClass, width: UInt32, height: UInt32, hz: Double) -> AnyObject? {
        guard let allocated = allocate(type) else { return nil }
        let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let method = class_getInstanceMethod(type, selector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Init.self)(allocated, selector, width, height, hz)?.takeRetainedValue()
    }

    private static func apply(_ settings: AnyObject, to display: AnyObject) -> Bool {
        let selector = NSSelectorFromString("applySettings:")
        guard let type = object_getClass(display), let method = class_getInstanceMethod(type, selector) else { return false }
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
        return unsafeBitCast(method_getImplementation(method), to: Apply.self)(display, selector, settings).boolValue
    }
}
