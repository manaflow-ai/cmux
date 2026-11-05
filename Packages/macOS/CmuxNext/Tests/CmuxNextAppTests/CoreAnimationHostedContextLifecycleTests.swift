import AppKit
import CmuxNextCompat
import CmuxNextTestSupport
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import IOSurface
import ObjectiveC
import QuartzCore
import ScreenCaptureKit
import Testing

/// SPIKE (scratch/frame-owner-s4-fence-spike-nomerge, never merged): the lifecycle of fix (a), the joined layer in its
/// own CAContext shown through a CALayerHost (``CoreAnimationHostedContext``). Each case prints one
/// `FENCE-SPIKE {json}` line, as ``CoreAnimationFenceSpikeTests`` does.
///
/// 1. Close with a fence held on the hosted context (the off-main side has not committed): with the teardown (release
///    the port, `-[CAContext invalidate]`, remove the CALayerHost) and without it. Then a NEW window with its own
///    hosted context and fence shows its first frame: how long after its commit, so a commit left held by the closed
///    window would show as a wait.
/// 2. Scale: the window moves 2 -> 1 -> 2 between a real Retina-scale display and a virtual display at scale 1
///    (CGVirtualDisplay, the API scripts/ci/frame-pacing/vdisplay.m uses). The hosted layer's picture is a 1-pixel
///    checkerboard: at the right contentsScale each pixel is one pixel; at a wrong one it is resampled and reads as an
///    even grey. Measured without and with a contentsScale update on the window's backing-change notification.
/// 3. Display move: with the virtual display, between the two displays: does the CALayerHost still show the context.
@MainActor @Suite(.serialized, .closesItsWindows,
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct CoreAnimationHostedContextLifecycleTests {
    // MARK: - 1. Close

    @Test func closeWithAFenceHeld() async throws {
        for teardown in [true, false] {
            var line: [String: Any] = ["case": teardown ? "close_with_teardown" : "close_without_teardown"]
            let first = try HostedWindow(origin: CGPoint(x: 120, y: 120), color: (0, 0, 255))
            try await first.waitShown(timeout: 2)
            guard let fence = first.hosted?.fence, let port = fence.createFencePort() else {
                LifecycleReport.emit(["case": line["case"] ?? "", "error": "no fence on the hosted context"])
                first.window.close()
                continue
            }
            // The fenced main commit: new bounds on the hosted root; the off-main side never commits.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            first.root.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
            CATransaction.commit()
            try await Task.sleep(for: .milliseconds(20))
            let closeStart = LifecycleClock.now
            let windowNumber = CGWindowID(first.window.windowNumber)
            var invalidated = false
            if teardown {
                CoreAnimationFence.release(port)
                invalidated = first.invalidateContext()
                CATransaction.begin()
                first.host?.removeFromSuperlayer()
                CATransaction.commit()
            }
            first.window.close()
            let closeCallMs = LifecycleClock.ms(closeStart, LifecycleClock.now)
            let goneMs = await LifecycleClock.until(timeout: 3) { !Self.windowOnScreen(windowNumber) }
                .map { LifecycleClock.ms(closeStart, $0) }
            line["invalidate_selector"] = invalidated
            line["close_call_ms"] = closeCallMs
            line["window_gone_after_ms"] = goneMs ?? -1

            // The next window: its own context, its first frame with a fence released at once (a normal sync).
            let next = try HostedWindow(origin: CGPoint(x: 560, y: 120), color: (0, 255, 0))
            let shownAt = LifecycleClock.now
            let nextFirstFrameMs = try await next.waitShown(timeout: 3).map { LifecycleClock.ms(shownAt, $0) }
            line["next_window_first_frame_ms"] = nextFirstFrameMs ?? -1
            var nextFenceMs: Double = -1
            if let nextFence = next.hosted?.fence, let nextPort = nextFence.createFencePort() {
                let fenced = LifecycleClock.now
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                next.setColor((255, 0, 0))
                CATransaction.commit()
                CoreAnimationFence.release(nextPort)
                if let at = try await next.waitColor(.red, timeout: 3) { nextFenceMs = LifecycleClock.ms(fenced, at) }
            }
            line["next_window_fenced_frame_ms"] = nextFenceMs
            if !teardown { CoreAnimationFence.release(port) } // after the measure: the case without the teardown
            next.close()
            LifecycleReport.emit(line)
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - 2 and 3. Scale and display move

    @Test func scaleAndDisplayMove() async throws {
        let real = NSScreen.main
        let retinaReal = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
        let virtual = VirtualDisplay(width: 1280, height: 800)
        // No 2x display on the mini: a second virtual display, hiDPI (scale 2), stands in for the Retina one.
        let virtual2x = retinaReal == nil ? VirtualDisplay(width: 2560, height: 1600, hiDPI: true) : nil
        let virtual2xScreen = await virtual2x?.screen(timeout: 5)
        let realScreen = retinaReal ?? virtual2xScreen ?? real
        var line: [String: Any] = ["case": "scale_and_display_move",
                                   "real_scale": real?.backingScaleFactor ?? 0,
                                   "virtual_display": virtual != nil,
                                   "scale2_display": retinaReal != nil ? "real" : (virtual2xScreen != nil ? "virtual_hidpi" : "none"),
                                   "scale2_scale": realScreen?.backingScaleFactor ?? 0]
        guard let realScreen, let virtual, let virtualScreen = await virtual.screen(timeout: 5) else {
            line["result"] = "not tested: needs two displays (no virtual display)"
            LifecycleReport.emit(line)
            return
        }
        line["virtual_scale"] = virtualScreen.backingScaleFactor
        guard realScreen.backingScaleFactor != virtualScreen.backingScaleFactor else {
            line["result"] = "not tested: both displays have scale \(realScreen.backingScaleFactor)"
            LifecycleReport.emit(line)
            return
        }
        for updateScale in [false, true] {
            let mode = updateScale ? "with_update" : "without_update"
            let window = try HostedWindow(origin: CGPoint(x: realScreen.frame.minX + 120, y: realScreen.frame.minY + 120),
                                          color: nil, checker: true)
            window.updatesScaleOnBackingChange = updateScale
            try await window.waitShown(timeout: 2)
            var moves: [[String: Any]] = []
            for (name, screen) in [("to_virtual_1x", virtualScreen), ("back_to_real_2x", realScreen)] {
                let moved = LifecycleClock.now
                window.window.setFrameOrigin(CGPoint(x: screen.frame.minX + 100, y: screen.frame.minY + 100))
                let samples = try await window.checkerSamples(for: 0.6)
                let wrong = samples.filter { !$0.sharp }
                let firstSharp = samples.first { $0.sharp }.map { LifecycleClock.ms(moved, $0.time) }
                moves.append(["move": name, "window_scale": window.window.backingScaleFactor,
                              "frames": samples.count, "wrong_scale_frames": wrong.count,
                              "first_correct_frame_ms": firstSharp ?? -1,
                              "host_shows_context": samples.contains { $0.covered },
                              "layer_contents_scale": window.root.contentsScale])
            }
            var result = line
            result["case"] = "scale_\(mode)"
            result["moves"] = moves
            LifecycleReport.emit(result)
            window.close()
        }
        _ = virtual2x
    }

    /// Whether the window server still lists `window` on screen.
    static func windowOnScreen(_ window: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
    }
}

// MARK: - A window that shows a hosted context

@MainActor
private final class HostedWindow {
    static let size = CGSize(width: 240, height: 240)
    let window: NSWindow
    let root = CALayer()
    let hosted: CoreAnimationHostedContext?
    var host: CALayer? { hosted?.hostLayer }
    var updatesScaleOnBackingChange = false
    private var observer: (any NSObjectProtocol)?
    private let checker: Bool

    init(origin: CGPoint, color: (UInt8, UInt8, UInt8)?, checker: Bool = false) throws {
        _ = NSApplication.shared
        self.checker = checker
        window = NSWindow(contentRect: NSRect(origin: origin, size: Self.size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        window.contentView = view
        view.layer?.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        root.anchorPoint = .zero
        root.position = .zero
        root.bounds = CGRect(origin: .zero, size: CGSize(width: 160, height: 160))
        root.contentsGravity = .resize
        root.magnificationFilter = .linear
        root.minificationFilter = .linear
        window.orderFrontRegardless()
        hosted = CoreAnimationHostedContext(root: root)
        guard let hosted else { throw LifecycleError("no hosted context on this OS") }
        hosted.hostLayer.anchorPoint = .zero
        hosted.hostLayer.frame = CGRect(x: 40, y: 40, width: 160, height: 160)
        view.layer?.addSublayer(hosted.hostLayer)
        root.contentsScale = window.backingScaleFactor
        if checker { root.contents = Self.checkerboard(points: 160, scale: window.backingScaleFactor) }
        if let color { setColor(color) }
        CATransaction.flush()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backingChanged() }
        }
    }

    func setColor(_ rgb: (UInt8, UInt8, UInt8)) {
        root.backgroundColor = CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    /// The fix under test: the hosted tree takes the window's new scale (it does not inherit it through the host).
    private func backingChanged() {
        guard updatesScaleOnBackingChange else { return }
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.contentsScale = scale
        if checker { root.contents = Self.checkerboard(points: 160, scale: scale) }
        CATransaction.commit()
    }

    /// `-[CAContext invalidate]` when this OS has it.
    func invalidateContext() -> Bool {
        guard let context = hosted?.context else { return false }
        return CoreAnimationFenceLifecycle.invalidate(context)
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        _ = invalidateContext()
        host?.removeFromSuperlayer()
        window.close()
    }

    /// Waits until the window's picture shows the hosted root (not the white page); returns when it first did.
    @discardableResult
    func waitShown(timeout: Double) async throws -> UInt64? {
        await LifecycleClock.until(timeout: timeout) { [self] in
            guard let pixel = centerPixel() else { return false }
            return !(pixel.r > 240 && pixel.g > 240 && pixel.b > 240)
        }
    }

    enum Shade { case red }

    func waitColor(_ shade: Shade, timeout: Double) async throws -> UInt64? {
        await LifecycleClock.until(timeout: timeout) { [self] in
            guard let pixel = centerPixel() else { return false }
            return pixel.r > 200 && pixel.g < 60 && pixel.b < 60
        }
    }

    /// The window's composited picture at its center, from the window server (this process's own window).
    private func centerPixel() -> (r: Int, g: Int, b: Int)? {
        guard let image = Self.windowImage(window.windowNumber),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let x = image.width / 2, y = image.height / 2
        let p = bytes + y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    /// One window's composited image at backing resolution (`CGWindowListCreateImage`, looked up at run time as
    /// NSWindow+Snapshot does: the SDK marks it unavailable). This process's own window needs no grant.
    nonisolated static func windowImage(_ windowNumber: Int) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard windowNumber > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution.
        return unsafeBitCast(symbol, to: CreateImage.self)(.null, 1 << 3, UInt32(windowNumber), (1 << 0) | (1 << 3))?
            .takeRetainedValue()
    }

    struct CheckerSample {
        let time: UInt64
        /// Neighbouring pixels differ by more than half the range: the checkerboard is drawn 1:1.
        let sharp: Bool
        /// The host's area is not the white page (the context still shows).
        let covered: Bool
    }

    /// Samples the window's picture (best resolution: one image pixel per backing pixel) back to back for `seconds`.
    func checkerSamples(for seconds: Double) async throws -> [CheckerSample] {
        var samples: [CheckerSample] = []
        let end = LifecycleClock.now + UInt64(seconds * 1000 * LifecycleClock.ticksPerMs)
        while LifecycleClock.now < end {
            if let image = Self.windowImage(window.windowNumber),
               let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                let x = image.width / 2, y = image.height / 2, step = image.bitsPerPixel / 8
                func lum(_ dx: Int) -> Int {
                    let p = bytes + y * image.bytesPerRow + (x + dx) * step
                    return (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
                }
                let a = lum(0), b = lum(1)
                samples.append(CheckerSample(time: LifecycleClock.now, sharp: abs(a - b) > 128, covered: a < 240 || b < 240))
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        return samples
    }

    /// A checkerboard of single pixels at `scale` (black and white), `points` wide.
    static func checkerboard(points: Int, scale: CGFloat) -> IOSurfaceRef {
        let side = Int(CGFloat(points) * scale)
        let properties: [CFString: Any] = [kIOSurfaceWidth: side, kIOSurfaceHeight: side, kIOSurfaceBytesPerElement: 4,
                                           kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
        let surface = IOSurfaceCreate(properties as CFDictionary)!
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let row = IOSurfaceGetBytesPerRow(surface)
        for y in 0..<side {
            for x in 0..<side {
                let v: UInt8 = (x + y) % 2 == 0 ? 0 : 255
                let p = base + y * row + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }
}

// MARK: - CGVirtualDisplay (SPI, as scripts/ci/frame-pacing/vdisplay.m)

/// A virtual display at scale 1 (hiDPI off), alive as long as this object. nil when this OS has no CGVirtualDisplay.
@MainActor
private final class VirtualDisplay {
    private let display: NSObject
    let displayID: CGDirectDisplayID

    private typealias InitFunction = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<NSObject>?
    private typealias ModeInit = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<NSObject>?
    private typealias ApplyFunction = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    private typealias IDFunction = @convention(c) (AnyObject, Selector) -> UInt32

    /// `+alloc` for an init call through a function pointer: one extra retain, because `-init...` consumes self and
    /// Swift passes it at +0 (without it the object is released once too often).
    private static func allocForInit(_ cls: AnyClass) -> AnyObject? {
        guard let instance = class_createInstance(cls, 0) else { return nil }
        _ = Unmanaged.passRetained(instance as AnyObject)
        return instance as AnyObject
    }

    /// - Parameter hiDPI: true for a scale-2 display (`width` x `height` are pixels; points are half).
    init?(width: UInt32, height: UInt32, hiDPI: Bool = false) {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else { return nil }
        let descriptor = descriptorClass.init()
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        descriptor.setValue(hiDPI ? "fence-spike 2x" : "fence-spike 1x", forKey: "name")
        descriptor.setValue(width, forKey: "maxPixelsWide")
        descriptor.setValue(height, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: CGSize(width: 600, height: 600.0 * Double(height) / Double(width))), forKey: "sizeInMillimeters")
        descriptor.setValue(0x6673, forKey: "productID")
        descriptor.setValue(0x6673, forKey: "vendorID")
        descriptor.setValue(hiDPI ? 8 : 7, forKey: "serialNum")
        let initSel = sel_registerName("initWithDescriptor:")
        guard let initMethod = class_getInstanceMethod(displayClass, initSel),
              let blank = Self.allocForInit(displayClass),
              let made = unsafeBitCast(method_getImplementation(initMethod), to: InitFunction.self)(blank, initSel, descriptor)?
                  .takeRetainedValue() else { return nil }
        let modeSel = sel_registerName("initWithWidth:height:refreshRate:")
        guard let modeMethod = class_getInstanceMethod(modeClass, modeSel),
              let blankMode = Self.allocForInit(modeClass),
              let mode = unsafeBitCast(method_getImplementation(modeMethod), to: ModeInit.self)(blankMode, modeSel, hiDPI ? width / 2 : width, hiDPI ? height / 2 : height, 60)?
                  .takeRetainedValue() else { return nil }
        let settings = settingsClass.init()
        settings.setValue(hiDPI ? 1 : 0, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        let applySel = sel_registerName("applySettings:")
        guard let applyMethod = class_getInstanceMethod(displayClass, applySel),
              unsafeBitCast(method_getImplementation(applyMethod), to: ApplyFunction.self)(made, applySel, settings) else { return nil }
        let idSel = sel_registerName("displayID")
        guard let idMethod = class_getInstanceMethod(displayClass, idSel) else { return nil }
        display = made
        displayID = unsafeBitCast(method_getImplementation(idMethod), to: IDFunction.self)(made, idSel)
    }

    /// AppKit's screen for this display, once AppKit lists it (it refreshes its list on the main run loop).
    func screen(timeout: Double) async -> NSScreen? {
        let end = LifecycleClock.now + UInt64(timeout * 1000 * LifecycleClock.ticksPerMs)
        while LifecycleClock.now < end {
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }) { return screen }
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = display
        return nil
    }
}

// MARK: - Helpers

private nonisolated enum LifecycleClock {
    static let ticksPerMs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e6 * Double(info.denom) / Double(info.numer)
    }()
    static var now: UInt64 { mach_absolute_time() }
    static func ms(_ from: UInt64, _ to: UInt64) -> Double { ((Double(to) - Double(from)) / ticksPerMs * 100).rounded() / 100 }

    /// Polls `check` every 4 ms on the main actor until it holds (returns when) or `timeout` seconds pass (nil).
    @MainActor
    static func until(timeout: Double, _ check: @MainActor () -> Bool) async -> UInt64? {
        let end = now + UInt64(timeout * 1000 * ticksPerMs)
        while now < end {
            if check() { return now }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return nil
    }
}

private nonisolated enum LifecycleReport {
    static func emit(_ fields: [String: Any]) {
        var fields = fields
        fields["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        fields["host"] = ProcessInfo.processInfo.hostName
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        print("FENCE-SPIKE \(String(decoding: data, as: UTF8.self))")
    }
}

/// `-[CAContext invalidate]`, resolved at run time.
private nonisolated enum CoreAnimationFenceLifecycle {
    private typealias VoidFunction = @convention(c) (AnyObject, Selector) -> Void
    static func invalidate(_ context: NSObject) -> Bool {
        let selector = sel_registerName("invalidate")
        guard let method = class_getInstanceMethod(type(of: context), selector) else { return false }
        unsafeBitCast(method_getImplementation(method), to: VoidFunction.self)(context, selector)
        return true
    }
}

private nonisolated struct LifecycleError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
