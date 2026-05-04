import Foundation
import ObjectiveC

enum SimulatorButton {
    case home, lock
}

/// Drives input into a booted simulator via SimulatorKit's host-HID
/// pipeline. Uses the 9-arg `IndigoHIDMessageForMouseNSEvent` recipe
/// from Xcode 26's preview-kit (verified by tddworks/baguette).
///
/// Dispatch path:
///   - Receiver is a `SimDeviceLegacyHIDClient` instance (resolved via
///     `SimulatorCapabilities` so we tolerate Swift mangling drift).
///   - Each Indigo HID message is delivered with
///     `sendWithMessage:freeWhenDone:completionQueue:completion:`.
///
/// Coordinate convention: callers pass click coords in DEVICE POINTS
/// (e.g. 215×467 for the centre of an iPhone 17 Pro Max), with the
/// device's logical screen size in points as `deviceSize`. The C
/// function expects both in the same unit. We convert from view coords
/// elsewhere.
///
/// All failures are non-fatal: each entrypoint returns false and writes
/// the reason to `lastError`, so the UI can show "couldn't dispatch
/// touch" instead of crashing.
final class IndigoHIDInput: @unchecked Sendable {
    private let udid: String

    private typealias MouseFn = @convention(c) (
        UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?,
        UInt32, UInt32, UInt32,
        Double, Double,
        Double, Double
    ) -> UnsafeMutableRawPointer?
    private typealias ButtonFn = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ServiceFn = @convention(c) () -> UnsafeMutableRawPointer?

    private let lock = NSLock()
    private var client: AnyObject?
    private var mouseFn: MouseFn?
    private var buttonFn: ButtonFn?
    private var createPointerSvc: ServiceFn?
    private var createMouseSvc: ServiceFn?
    private var removePointerSvc: ServiceFn?

    private var _lastError: String?
    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastError
    }

    private static let touchDigitizer: UInt32 = 0x32
    private static let nsEventDown:    UInt32 = 1
    private static let nsEventUp:      UInt32 = 2
    private static let nsEventDragged: UInt32 = 6
    private static let dirDown: UInt32 = 1
    private static let dirMove: UInt32 = 0
    private static let dirUp:   UInt32 = 2

    init(udid: String) {
        self.udid = udid
    }

    deinit {
        if let client, let remove = removePointerSvc, let msg = remove() {
            send(message: msg, to: client)
        }
    }

    enum TouchPhase { case down, move, up }

    // MARK: - public

    @discardableResult
    func tap(at point: CGPoint, deviceSize: CGSize, duration: Double = 0.05) -> Bool {
        guard let c = ensureWarm() else { return false }
        guard sendMouse(client: c, p1: point, p2: nil, eventType: Self.nsEventDown, direction: Self.dirDown, deviceSize: deviceSize) else {
            return false
        }
        usleep(UInt32(max(0.01, duration) * 1_000_000))
        return sendMouse(client: c, p1: point, p2: nil, eventType: Self.nsEventUp, direction: Self.dirUp, deviceSize: deviceSize)
    }

    @discardableResult
    func drag(from start: CGPoint, to end: CGPoint, deviceSize: CGSize, duration: Double = 0.25) -> Bool {
        guard let c = ensureWarm() else { return false }
        let total = max(0.05, duration)
        let steps = 12
        let stepUs = UInt32((total / Double(steps + 2)) * 1_000_000)
        guard sendMouse(client: c, p1: start, p2: nil, eventType: Self.nsEventDown, direction: Self.dirDown, deviceSize: deviceSize) else {
            return false
        }
        var ok = 0
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            usleep(stepUs)
            if sendMouse(client: c, p1: p, p2: nil, eventType: Self.nsEventDragged, direction: Self.dirMove, deviceSize: deviceSize) { ok += 1 }
        }
        _ = sendMouse(client: c, p1: end, p2: nil, eventType: Self.nsEventUp, direction: Self.dirUp, deviceSize: deviceSize)
        return ok >= steps / 2
    }

    @discardableResult
    func touchPhase(_ phase: TouchPhase, at point: CGPoint, deviceSize: CGSize) -> Bool {
        guard let c = ensureWarm() else { return false }
        let (et, dir) = mouseEvent(for: phase)
        return sendMouse(client: c, p1: point, p2: nil, eventType: et, direction: dir, deviceSize: deviceSize)
    }

    /// Force the warmup path eagerly so the first user gesture doesn't
    /// pay the ~40ms pointer + mouse service spin-up.
    @discardableResult
    func prewarm() -> Bool {
        return ensureWarm() != nil
    }

    @discardableResult
    func press(_ button: SimulatorButton) -> Bool {
        guard let c = ensureWarm() else { return false }
        guard let bfn = buttonFn else { recordError("button function symbol unavailable"); return false }
        let (arg0, target) = buttonCodes(for: button)
        guard let down = bfn(arg0, 1, target) else { recordError("button down msg construct failed"); return false }
        send(message: down, to: c)
        usleep(100_000)
        guard let up = bfn(arg0, 2, target) else { recordError("button up msg construct failed"); return false }
        send(message: up, to: c)
        return true
    }

    // MARK: - warmup

    private func ensureWarm() -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        if let client { return client }

        let report = SimulatorCapabilities.report()
        if case .unavailable(let reason) = report.input {
            recordErrorLocked("input unavailable: \(reason)")
            return nil
        }
        guard let device = (try? SimulatorService.shared.resolveDevice(udid: udid)) ?? nil else {
            recordErrorLocked("device not found for udid \(udid)")
            return nil
        }
        guard resolveSymbols() else {
            recordErrorLocked("dlsym failed for IndigoHIDMessageForMouseNSEvent")
            return nil
        }
        guard let cls = SimulatorCapabilities.resolveHIDClientClass() else {
            recordErrorLocked("no HID client class in this SimulatorKit")
            return nil
        }
        guard let metaCls = object_getClass(cls) else {
            recordErrorLocked("HID client meta class missing")
            return nil
        }
        let allocSel = NSSelectorFromString("alloc")
        guard let allocImp = class_getMethodImplementation(metaCls, allocSel) else {
            recordErrorLocked("HID client +alloc missing")
            return nil
        }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject?
        guard let allocated = unsafeBitCast(allocImp, to: AllocFn.self)(cls, allocSel) else {
            recordErrorLocked("HID client +alloc returned nil")
            return nil
        }
        let initSel = NSSelectorFromString("initWithDevice:error:")
        guard let initImp = class_getMethodImplementation(cls, initSel) else {
            recordErrorLocked("HID client -initWithDevice:error: missing")
            return nil
        }
        typealias InitFn = @convention(c) (
            AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        var initErr: NSError?
        guard let c = unsafeBitCast(initImp, to: InitFn.self)(allocated, initSel, device, &initErr) else {
            let detail = initErr?.localizedDescription ?? "unknown"
            recordErrorLocked("HID client init failed: \(detail)")
            return nil
        }
        client = c

        if let create = createPointerSvc, let msg = create() {
            send(message: msg, to: c)
            usleep(20_000)
        }
        if let create = createMouseSvc, let msg = create() {
            send(message: msg, to: c)
            usleep(20_000)
        }

        return c
    }

    private func resolveSymbols() -> Bool {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let sym = dlsym(handle, "IndigoHIDMessageForMouseNSEvent") else { return false }
        mouseFn = unsafeBitCast(sym, to: MouseFn.self)
        if let s = dlsym(handle, "IndigoHIDMessageForButton") {
            buttonFn = unsafeBitCast(s, to: ButtonFn.self)
        }
        if let s = dlsym(handle, "IndigoHIDMessageToCreatePointerService") {
            createPointerSvc = unsafeBitCast(s, to: ServiceFn.self)
        }
        if let s = dlsym(handle, "IndigoHIDMessageToCreateMouseService") {
            createMouseSvc = unsafeBitCast(s, to: ServiceFn.self)
        }
        if let s = dlsym(handle, "IndigoHIDMessageToRemovePointerService") {
            removePointerSvc = unsafeBitCast(s, to: ServiceFn.self)
        }
        return true
    }

    // MARK: - dispatch

    private func sendMouse(
        client: AnyObject,
        p1: CGPoint, p2: CGPoint?,
        eventType: UInt32, direction: UInt32,
        deviceSize: CGSize
    ) -> Bool {
        guard let mfn = mouseFn else { recordError("mouse function symbol unavailable"); return false }
        guard deviceSize.width > 0, deviceSize.height > 0 else {
            recordError("deviceSize is zero — no frame yet?")
            return false
        }
        let maxAttempts = (p2 != nil) ? 12 : 3
        var pt1 = CGPoint(
            x: clamp01(p1.x / deviceSize.width),
            y: clamp01(p1.y / deviceSize.height)
        )
        var msg: UnsafeMutableRawPointer?
        if let p2 {
            var pt2 = CGPoint(
                x: clamp01(p2.x / deviceSize.width),
                y: clamp01(p2.y / deviceSize.height)
            )
            for _ in 0..<maxAttempts {
                msg = withUnsafePointer(to: &pt1) { p1Ref in
                    withUnsafePointer(to: &pt2) { p2Ref in
                        mfn(p1Ref, p2Ref, Self.touchDigitizer, eventType, direction, 1.0, 1.0, deviceSize.width, deviceSize.height)
                    }
                }
                if msg != nil { break }
                usleep(5_000)
            }
        } else {
            for _ in 0..<maxAttempts {
                msg = withUnsafePointer(to: &pt1) { p1Ref in
                    mfn(p1Ref, nil, Self.touchDigitizer, eventType, direction, 1.0, 1.0, deviceSize.width, deviceSize.height)
                }
                if msg != nil { break }
                usleep(5_000)
            }
        }
        guard let msg else {
            recordError("mouse msg builder returned nil after \(maxAttempts) attempts")
            return false
        }
        send(message: msg, to: client)
        return true
    }

    private func send(message: UnsafeMutableRawPointer, to client: AnyObject) {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client) else { return }
        guard let imp = class_getMethodImplementation(cls, sel) else {
            recordError("\(NSStringFromClass(cls)) lacks sendWithMessage:…:completion:")
            return
        }
        typealias Fn = @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?
        ) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, message, ObjCBool(true), nil, nil)
    }

    private func mouseEvent(for phase: TouchPhase) -> (UInt32, UInt32) {
        switch phase {
        case .down: return (Self.nsEventDown, Self.dirDown)
        case .move: return (Self.nsEventDragged, Self.dirMove)
        case .up:   return (Self.nsEventUp, Self.dirUp)
        }
    }

    private func buttonCodes(for button: SimulatorButton) -> (UInt32, UInt32) {
        switch button {
        case .home: return (0x0, 0x33)
        case .lock: return (0x1, 0x33)
        }
    }

    private func clamp01(_ x: Double) -> Double {
        min(1.0, max(0.0, x))
    }

    private func recordError(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        recordErrorLocked(msg)
    }

    private func recordErrorLocked(_ msg: String) {
        _lastError = msg
#if DEBUG
        cmuxDebugLog("simulator.input udid=\(udid.prefix(8)) error: \(msg)")
#endif
    }
}
