import Foundation
import IOSurface
import ObjectiveC

/// Streams `IOSurface` framebuffer frames out of a booted simulator via
/// SimulatorKit's IOClient. Pure pass-through: emits exactly when
/// SimulatorKit composites a new frame. Cadence/throttling is the
/// consumer's responsibility.
final class SimulatorScreen: @unchecked Sendable {
    private let udid: String
    private let queue = DispatchQueue(label: "cmux.simulator.screen", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1

    private var ioClient: NSObject?
    private var descriptors: [NSObject] = []
    private var callbackUUIDs: [ObjectIdentifier: NSUUID] = [:]
    private var onFrame: (@Sendable (IOSurface, CGSize) -> Void)?

    /// Max delivery rate for emitted frames. SimulatorKit fires the
    /// callback at the device's native refresh (60 / 120 Hz). Each
    /// emit costs a CIImage->CGImage->NSImage round-trip plus a
    /// MainActor hop and a SwiftUI invalidation, so without a cap a
    /// single open viewer can saturate the main thread and lag the
    /// rest of the app. 30 fps is enough for visual confirmation
    /// while leaving headroom for everything else.
    private let maxEmitsPerSecond: Double = 30
    private var lastEmitTime: CFAbsoluteTime = 0
    private var captureScheduled = false

    init(udid: String) {
        self.udid = udid
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    func start(
        onFrame: @escaping @Sendable (IOSurface, CGSize) -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                guard SimulatorPrivateFrameworks.ensureLoaded() else {
                    throw SimulatorError.frameworksUnavailable(
                        SimulatorPrivateFrameworks.loadErrorMessage ?? "unknown"
                    )
                }
                guard let device = try SimulatorService.shared.resolveDevice(udid: udid) else {
                    throw SimulatorError.notFound(udid: udid)
                }
                guard let io = device.perform(NSSelectorFromString("io"))?
                    .takeUnretainedValue() as? NSObject
                else {
                    throw SimulatorError.ioUnavailable
                }

                stopLocked()
                self.onFrame = onFrame
                self.ioClient = io
                try wireFramebufferLocked()
                completion(.success(()))
            } catch {
                stopLocked()
                completion(.failure(error))
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == queueValue {
            stopLocked()
        } else {
            queue.async { [self] in
                stopLocked()
            }
        }
    }

    private func stopLocked() {
        let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for desc in descriptors {
            if let uuid = callbackUUIDs[ObjectIdentifier(desc)],
               desc.responds(to: unregSel) {
                desc.perform(unregSel, with: uuid)
            }
        }
        descriptors.removeAll()
        callbackUUIDs.removeAll()
        ioClient = nil
        onFrame = nil
    }

    // MARK: - private

    private func wireFramebufferLocked() throws {
        guard let io = ioClient else { throw SimulatorError.ioUnavailable }
        io.perform(NSSelectorFromString("updateIOPorts"))

        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw SimulatorError.ioUnavailable
        }

        let pidSel = NSSelectorFromString("portIdentifier")
        let descSel = NSSelectorFromString("descriptor")
        let surfSel = NSSelectorFromString("framebufferSurface")

        var candidates: [NSObject] = []
        for port in ports where port.responds(to: pidSel) {
            guard let pid = port.perform(pidSel)?.takeUnretainedValue(),
                  "\(pid)" == "com.apple.framebuffer.display",
                  port.responds(to: descSel),
                  let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: surfSel)
            else { continue }
            candidates.append(desc)
        }
        guard !candidates.isEmpty else { throw SimulatorError.ioUnavailable }
        descriptors = candidates

        for desc in candidates {
            try registerCallbacks(on: desc)
        }
    }

    private func registerCallbacks(on desc: NSObject) throws {
        let regSel = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:" +
                "surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard desc.responds(to: regSel) else { throw SimulatorError.ioUnavailable }

        let uuid = NSUUID()
        callbackUUIDs[ObjectIdentifier(desc)] = uuid

        let frame: @convention(block) () -> Void = { [weak self] in
            self?.scheduleCaptureCoalesced()
        }
        let surfaces: @convention(block) () -> Void = { [weak self] in
            self?.scheduleCaptureCoalesced()
        }
        let props: @convention(block) () -> Void = {}

        guard let imp = class_getMethodImplementation(type(of: desc), regSel) else {
            throw SimulatorError.ioUnavailable
        }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject
        ) -> Void
        unsafeBitCast(imp, to: Fn.self)(
            desc, regSel,
            uuid, queue as AnyObject,
            frame as AnyObject, surfaces as AnyObject, props as AnyObject
        )
    }

    /// Coalesces frame callbacks into at most one in-flight capture on
    /// our serial queue. SimulatorKit can fire the callback faster than
    /// we drain it; without coalescing each callback queues another
    /// captureLatest, even if one is already pending. With coalescing,
    /// while a capture is queued or running, additional callbacks are
    /// no-ops.
    private func scheduleCaptureCoalesced() {
        if DispatchQueue.getSpecific(key: queueKey) != queueValue {
            queue.async { [weak self] in
                self?.scheduleCaptureCoalesced()
            }
            return
        }
        let shouldSchedule = {
            if captureScheduled { return false }
            captureScheduled = true
            return true
        }()
        guard shouldSchedule else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.captureLatest()
            self.captureScheduled = false
        }
    }

    private func captureLatest() {
        // Throttle delivery to the consumer. The capture itself is
        // cheap (just KVC + IOSurface area check) but the consumer's
        // CIImage / CGImage / NSImage round-trip and SwiftUI re-render
        // are not.
        let now = CFAbsoluteTimeGetCurrent()
        let minInterval = 1.0 / maxEmitsPerSecond
        if now - lastEmitTime < minInterval { return }

        let surfSel = NSSelectorFromString("framebufferSurface")
        var best: IOSurface?
        var bestSize = CGSize.zero
        var bestArea = 0
        for desc in descriptors {
            guard let surfObj = desc.perform(surfSel)?.takeUnretainedValue() else { continue }
            let surf = unsafeBitCast(surfObj, to: IOSurface.self)
            let ref = unsafeBitCast(surfObj, to: IOSurfaceRef.self)
            let w = IOSurfaceGetWidth(ref)
            let h = IOSurfaceGetHeight(ref)
            let area = w * h
            if area > bestArea {
                best = surf
                bestSize = CGSize(width: w, height: h)
                bestArea = area
            }
        }
        if let best {
            lastEmitTime = now
            onFrame?(best, bestSize)
        }
    }
}
