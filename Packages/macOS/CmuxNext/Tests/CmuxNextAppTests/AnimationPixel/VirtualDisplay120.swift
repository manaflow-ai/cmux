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

    let displayID: CGDirectDisplayID
    let screen: NSScreen
    let scale: CGFloat
    /// The display's refresh period in seconds, measured from its own display link.
    let refreshPeriod: Double
    /// The display exists while this reference does.
    private let display: AnyObject

    init(points: CGSize, scale: Int) async throws {
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
        descriptor.setValue(NSNumber(value: UInt32(0x6370)), forKey: "vendorID")
        // A new serial each time: macOS keeps per-display settings by serial.
        descriptor.setValue(NSNumber(value: UInt32.random(in: 1...UInt32.max)), forKey: "serialNum")
        guard let made = Self.make(displayType, initializer: "initWithDescriptor:", argument: descriptor) else {
            throw Failure(description: "CGVirtualDisplay initWithDescriptor: gave nil (no window server session?)")
        }
        display = made
        guard let mode = Self.makeMode(modeType, width: width, height: height, hz: Self.hz) else {
            throw Failure(description: "CGVirtualDisplayMode initWithWidth:height:refreshRate: gave nil")
        }
        let settings = settingsType.init()
        settings.setValue([mode], forKey: "modes")
        settings.setValue(NSNumber(value: UInt32(scale > 1 ? 1 : 0)), forKey: "hiDPI")
        guard Self.apply(settings, to: made) else { throw Failure(description: "CGVirtualDisplay applySettings: failed") }
        guard let number = (made as? NSObject)?.value(forKey: "displayID") as? NSNumber else {
            throw Failure(description: "CGVirtualDisplay has no displayID")
        }
        let id = number.uint32Value
        displayID = id
        // AppKit lists a new display on the main run loop, after its screen-parameters change.
        var listed: NSScreen?
        for _ in 0..<100 {
            listed = NSScreen.screens.first { Self.number(of: $0) == id }
            if let listed, listed.backingScaleFactor == CGFloat(scale) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let listed else { throw Failure(description: "AppKit did not list virtual display \(id) within 5 s") }
        guard listed.backingScaleFactor == CGFloat(scale) else {
            throw Failure(description: "virtual display \(id) is \(listed.backingScaleFactor)x, not \(scale)x")
        }
        screen = listed
        self.scale = CGFloat(scale)
        let period = try await Self.measurePeriod(listed)
        refreshPeriod = period
        guard abs(period - 1 / Self.hz) < 0.0005 else {
            throw Failure(description: "virtual display \(id) ticks every \(period * 1000) ms, not \(1000 / Self.hz) ms")
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
