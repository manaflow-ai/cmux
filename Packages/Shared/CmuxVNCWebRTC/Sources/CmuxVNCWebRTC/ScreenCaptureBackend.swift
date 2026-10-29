#if os(macOS)
import AppKit
import CmuxSafeConcurrency
import CmuxVNC
import CoreMedia
import Foundation
import ScreenCaptureKit

/// V2's frame source and input sink: ScreenCaptureKit captures one display
/// at its native pixel size, at 60 fps or the rate the stream agreed on (up
/// to 120 on ProMotion), only when it changes (NV12, straight to
/// the hardware encoder), and CGEvent posts the viewer's input as if from
/// this Mac's own keyboard and mouse. Needs Screen Recording and
/// Accessibility for the host app.
// Threads: SCStream's sample and error callbacks on the serial `queue`, start/select/stop on the host session's tasks,
// the display-change callback on the main thread. The lock is CmuxSafeConcurrency's `PlatformLock` beside the fields
// (the lock under its Mutex, for a type that keeps its state beside the lock), not a Mutex<State>: SCDisplay and
// SCStream are not Sendable, so a value inside a Mutex<State> could not be handed out to the async capture calls that
// need it after the lock is released; `lock` returns them and those calls run unlocked.
// crash-allow: every mutable field is read and written only inside `lock.withLock` (threads and lock shape: above).
public final class ScreenCaptureBackend: NSObject, ScreenBackend, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // concurrency-allow: held only to read or swap fields and to register the display callback, never across a capture call or a wait.
    private let lock = PlatformLock()
    // User-initiated, not user-interactive: no local frame waits on it, a viewer on another device does
    // (plans/cmux-next/threading-model.md, closed list).
    private let queue = DispatchQueue(label: "cmux.screen.capture", qos: .userInitiated)
    private let log: @Sendable (String) -> Void
    private var displays: [SCDisplay] = []
    private var current = 0
    private var stream: SCStream?
    /// The display `stream` captures (a frame rate change reconfigures it for that display).
    private var streamDisplay: SCDisplay?
    /// Goes up each time `stream` is set or cleared: a reconfiguration task
    /// holds the one it was started for, never the (non-Sendable) stream.
    private var streamGeneration = 0
    /// Each display's most frames per second (`NSScreen.maximumFramesPerSecond`), by display ID.
    private var frameRates: [CGDirectDisplayID: Int] = [:]
    /// The capture rate (``setFrameRate(_:)``).
    private var frameRate = ScreenQuality.baselineFrameRate
    private var onFrame: (@Sendable (CVPixelBuffer, CGRect) -> Void)?
    private var onDisplays: (@Sendable ([CGSize], Int) -> Void)?
    private let input = EventInjector()
    /// Stopped by the viewer: no recovery after that.
    private var stopped = false
    /// The display-change callback, and the backend it holds (retained, so a
    /// callback never reaches a freed backend) until `stop()` removes it.
    private var reconfiguration: (callback: CGDisplayReconfigurationCallBack, context: Unmanaged<ScreenCaptureBackend>)?

    public init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    public func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void,
                      displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let found = content.displays.sorted { $0.frame.minX < $1.frame.minX }
        // No shareable display (all asleep, or capture refused): fail the session, never index an empty list.
        guard !found.isEmpty else { throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "no display to capture"]) }
        let main = found.firstIndex { $0.displayID == CGMainDisplayID() } ?? 0
        let rates = await Self.displayFrameRates()
        lock.withLock {
            self.displays = found
            current = main
            frameRates = rates
            onFrame = frame
            onDisplays = displays
        }
        displays(found.map { pixelSize($0) }, main)
        try await capture(found[main])
        watchDisplays()
    }

    /// A display added, removed or changing mode: read the displays again
    /// and capture the streaming one at its new size (a stream configured for
    /// the old mode can stop delivering frames).
    private func watchDisplays() {
        // The context is this backend, retained by watchDisplays and released by stop() only
        // after the callback is removed (on the main thread, where the callbacks run), so a
        // callback always sees a live backend.
        let callback: CGDisplayReconfigurationCallBack = { _, flags, context in
            // SAFETY: Core Graphics hands back the context pointer given at registration.
            guard !flags.contains(.beginConfigurationFlag), let context = unsafe context else { return }
            // SAFETY: the context is the +1 backend (ownership above); the unretained read does
            // not change its count.
            let backend = unsafe Unmanaged<ScreenCaptureBackend>.fromOpaque(context).takeUnretainedValue()
            backend.recover("displays changed")
        }
        // Registered under the lock, and never after stop(): stop() then always removes it.
        lock.withLock {
            // SAFETY: reads the stored registration; its context is only released by stop().
            guard !stopped, unsafe reconfiguration == nil else { return }
            // SAFETY: the +1 the callback's context holds, released once by stop().
            let context = unsafe Unmanaged.passRetained(self)
            // SAFETY: stores the registration stop() removes and releases exactly once.
            unsafe reconfiguration = (callback, context)
            // SAFETY: the context pointer is the +1 backend above, live until stop() removes this
            // callback and only then releases it.
            _ = unsafe CGDisplayRegisterReconfigurationCallback(callback, context.toOpaque())
        }
    }

    /// Captures the current display again (after a reconfiguration or a stream error).
    private func recover(_ reason: String) {
        guard !lock.withLock({ stopped }) else { return }
        log("capture restarting: \(reason)")
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let found = content.displays.sorted { $0.frame.minX < $1.frame.minX }
            guard !found.isEmpty else { return }
            // A mode change can change the refresh rate too (ProMotion off, another display).
            let rates = await Self.displayFrameRates()
            let (display, sizes, index, notify) = lock.withLock { () -> (SCDisplay, [CGSize], Int, (@Sendable ([CGSize], Int) -> Void)?) in
                let previous = displays.indices.contains(current) ? displays[current].displayID : CGMainDisplayID()
                frameRates = rates
                displays = found
                current = found.firstIndex { $0.displayID == previous } ?? (found.firstIndex { $0.displayID == CGMainDisplayID() } ?? 0)
                return (found[current], found.map { pixelSize($0) }, current, onDisplays)
            }
            notify?(sizes, index)
            try? await capture(display)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard lock.withLock({ self.stream === stream }) else { return }
        recover("stream stopped: \(error.localizedDescription)")
    }

    /// The display's size in pixels (Retina displays capture at full density).
    private func pixelSize(_ display: SCDisplay) -> CGSize {
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        return CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
    }

    /// Every display's most frames per second, by display ID (AppKit reads screens on the main thread).
    private static func displayFrameRates() async -> [CGDirectDisplayID: Int] {
        await MainActor.run {
            var rates: [CGDirectDisplayID: Int] = [:]
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                rates[number.uint32Value] = screen.maximumFramesPerSecond
            }
            return rates
        }
    }

    public var maximumFrameRate: Int? {
        lock.withLock { displays.indices.contains(current) ? frameRates[displays[current].displayID] : nil }
    }

    /// The capture rate for a stream at `fps`: the agreed rate, never below
    /// the 60 every preset captured at before (a fixed preset's encoder
    /// takes 30 of them, as it always did).
    static func captureFrameRate(for fps: Int) -> Int {
        min(max(fps, ScreenQuality.baselineFrameRate), ScreenQuality.maximumFrameRate)
    }

    /// Surfaces ScreenCaptureKit may have in flight. A frame stays out until
    /// the encoder lets it go; at 120 fps each one comes back in half the
    /// time, so two more keep capture from waiting on the encoder (8 is
    /// ScreenCaptureKit's limit).
    static func queueDepth(for fps: Int) -> Int {
        fps > ScreenQuality.baselineFrameRate ? 6 : 4
    }

    public func setFrameRate(_ fps: Int) {
        let rate = Self.captureFrameRate(for: fps)
        let generation = lock.withLock { () -> Int? in
            guard rate != frameRate else { return nil }
            frameRate = rate
            return stream == nil || streamDisplay == nil ? nil : streamGeneration
        }
        guard let generation else { return }
        reconfigure(generation: generation)
    }

    /// Brings a running capture to the current ``setFrameRate(_:)`` rate
    /// without restarting it. Changes in quick succession each start one of
    /// these; each reads the rate again after applying, so the capture
    /// always ends at the latest one whatever order they finish in.
    ///
    /// The task carries only `generation` (ScreenCaptureKit's objects are
    /// not Sendable): each pass takes the stream and its display from the
    /// backend under `lock`, and ends once `stream` was replaced or cleared.
    private func reconfigure(generation: Int) {
        let log = self.log
        Task {
            var applied: Int?
            while true {
                let running = lock.withLock { () -> (stream: SCStream, display: SCDisplay, rate: Int)? in
                    guard !stopped, streamGeneration == generation, let stream = self.stream,
                          let streamDisplay else { return nil }
                    return (stream, streamDisplay, self.frameRate)
                }
                guard let running, running.rate != applied else { return }
                let rate = running.rate
                do {
                    try await running.stream.updateConfiguration(configuration(for: running.display, frameRate: rate))
                    log("capturing display \(running.display.displayID) at \(rate) fps")
                } catch {
                    log("capture frame rate \(rate) not applied: \(error.localizedDescription)")
                    return
                }
                applied = rate
            }
        }
    }

    /// The pointer stays in the picture (`showsCursor`): the viewer shows the
    /// Mac's own cursor, never one drawn locally.
    private func configuration(for display: SCDisplay, frameRate: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let size = pixelSize(display)
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = Self.queueDepth(for: frameRate)
        configuration.showsCursor = true
        return configuration
    }

    private func capture(_ display: SCDisplay) async throws {
        let rate = lock.withLock { frameRate }
        let configuration = configuration(for: display, frameRate: rate)
        let size = pixelSize(display)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        // stop() may have run while this capture started: it then ends here, never stored.
        let (previous, late, latest, generation) = lock.withLock { () -> (SCStream?, Bool, Int, Int) in
            if stopped { return (nil, true, rate, streamGeneration) }
            defer {
                self.stream = stream
                streamDisplay = display
                streamGeneration += 1
            }
            return (self.stream, false, frameRate, streamGeneration + 1)
        }
        if late {
            try? await stream.stopCapture()
            return
        }
        if let previous { try? await previous.stopCapture() }
        input.setDisplay(display.frame)
        log("capturing display \(display.displayID) at \(Int(size.width))x\(Int(size.height)), \(rate) fps")
        // The rate changed while this capture started (setFrameRate found no stream to update).
        if latest != rate { reconfigure(generation: generation) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        let sink = lock.withLock { onFrame }
        sink?(buffer, CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
    }

    public func select(display index: Int) {
        let target = lock.withLock { () -> (SCDisplay, [CGSize], (@Sendable ([CGSize], Int) -> Void)?)? in
            guard displays.indices.contains(index), index != current else { return nil }
            current = index
            return (displays[index], displays.map { pixelSize($0) }, onDisplays)
        }
        guard let target else { return }
        target.2?(target.1, index)
        Task { try? await capture(target.0) }
    }

    public func handle(_ message: ScreenInput) {
        input.handle(message)
    }

    public func stop() {
        // SAFETY: takes the registration out under the lock, so exactly one stop() gets it.
        let (stream, reconfiguration) = unsafe lock.withLock { () -> (SCStream?, (callback: CGDisplayReconfigurationCallBack, context: Unmanaged<ScreenCaptureBackend>)?) in
            defer {
                self.stream = nil
                streamDisplay = nil
                streamGeneration += 1
                stopped = true
                // SAFETY: clears the field; the value moved out above.
                unsafe self.reconfiguration = nil
            }
            // SAFETY: moves the registration out; nothing else releases it.
            return (self.stream, unsafe self.reconfiguration)
        }
        // SAFETY: the registration this stop() took out, the only one to release it.
        if let reconfiguration = unsafe reconfiguration {
            // On the main thread, where the callbacks run: none is mid-call when
            // the hold it used is released.
            let release = { @Sendable in
                // SAFETY: removes the callback registered with this context; after it no callback
                // can receive the context.
                unsafe CGDisplayRemoveReconfigurationCallback(reconfiguration.callback, reconfiguration.context.toOpaque())
                // SAFETY: releases the +1 watchDisplays took, once, after the callback is gone.
                unsafe reconfiguration.context.release()
            }
            if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
        }
        if let stream { Task { try? await stream.stopCapture() } }
    }
}

/// Posts input with CGEvent at the HID level (Accessibility permission):
/// absolute pointer positions on the streamed display, button transitions
/// with click counting, wheel scrolling, keys by virtual key code, and text
/// as Unicode strings. The input channel's callbacks post, and a capture
/// start (its own task) moves the display, both under `state`.
final class EventInjector: Sendable {
    private let state = Mutex(Poster())

    func handle(_ input: ScreenInput) {
        state.withLock { $0.handle(input) }
    }

    /// The display pointer positions are on (its frame in global coordinates).
    func setDisplay(_ frame: CGRect) {
        state.withLock { $0.display = frame }
    }

    /// macOS virtual key codes (ANSI layout) by keysym; `shifted` for the
    /// upper symbol of a key.
    static func keyCode(for keysym: UInt32) -> (CGKeyCode, Bool)? {
        Poster.keyCode(for: keysym)
    }
}

/// The injector's event source and pointer, button and modifier state.
private struct Poster {
    var display = CGRect.zero
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttons: UInt8 = 0
    private var point = CGPoint.zero
    private var lastClick: (time: TimeInterval, button: UInt8, count: Int64) = (0, 0, 0)
    private var flags: CGEventFlags = []

    mutating func handle(_ input: ScreenInput) {
        switch input.t {
        case "move":
            point = location(input)
            setButtons(input.b ?? 0)
        case "scroll":
            point = location(input)
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
            post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                         wheel1: input.wheel.dy, wheel2: input.wheel.dx, wheel3: 0))
        case "key":
            guard let keysym = input.k else { return }
            key(keysym, down: input.d ?? true)
        case "chord":
            guard let keysym = input.k else { return }
            let modifiers = input.m ?? []
            for modifier in modifiers { key(modifier, down: true) }
            key(keysym, down: true)
            key(keysym, down: false)
            for modifier in modifiers.reversed() { key(modifier, down: false) }
        case "text":
            for character in input.s ?? "" { type(character) }
        default:
            break
        }
    }

    private func location(_ input: ScreenInput) -> CGPoint {
        input.location(in: display)
    }

    /// Moves, then posts a down or up for each button whose state changed.
    private mutating func setButtons(_ next: UInt8) {
        let changed = next ^ buttons
        let held = buttons
        buttons = next
        if changed == 0 {
            let type: CGEventType = held & 1 != 0 ? .leftMouseDragged : held & 4 != 0 ? .rightMouseDragged : .mouseMoved
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
            return
        }
        for (bit, button, down, up) in [(UInt8(1), CGMouseButton.left, CGEventType.leftMouseDown, CGEventType.leftMouseUp),
                                        (4, .right, .rightMouseDown, .rightMouseUp), (2, .center, .otherMouseDown, .otherMouseUp)]
            where changed & bit != 0 {
            let pressing = next & bit != 0
            let event = CGEvent(mouseEventSource: source, mouseType: pressing ? down : up, mouseCursorPosition: point, mouseButton: button)
            if pressing {
                // Double and triple clicks: macOS counts them from the click state.
                let now = ProcessInfo.processInfo.systemUptime
                let count = now - lastClick.time < NSEvent.doubleClickInterval && lastClick.button == bit ? lastClick.count + 1 : 1
                lastClick = (now, bit, count)
            }
            event?.setIntegerValueField(.mouseEventClickState, value: lastClick.count)
            post(event)
        }
    }

    private mutating func key(_ keysym: UInt32, down: Bool) {
        if let flag = Self.modifierFlags[keysym] {
            if down { flags.insert(flag) } else { flags.remove(flag) }
        }
        guard let (code, shifted) = Self.keyCode(for: keysym) else {
            if down, let scalar = Self.scalar(for: keysym) { type(Character(scalar)) }
            return
        }
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = shifted ? flags.union(.maskShift) : flags
        post(event)
    }

    private func type(_ character: Character) {
        let utf16 = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            // SAFETY: CGEvent copies stringLength = utf16.count UTF-16 units from the array, which
            // Swift keeps alive for this call only.
            unsafe event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event?.flags = flags
            post(event)
        }
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private static let modifierFlags: [UInt32: CGEventFlags] = [
        0xFFE1: .maskShift, 0xFFE2: .maskShift, 0xFFE3: .maskControl, 0xFFE4: .maskControl,
        0xFFE9: .maskAlternate, 0xFFEA: .maskAlternate, 0xFFEB: .maskCommand, 0xFFEC: .maskCommand,
        0xFFE7: .maskCommand, 0xFFE8: .maskCommand,
    ]

    private static func scalar(for keysym: UInt32) -> Unicode.Scalar? {
        keysym <= 0xFF ? Unicode.Scalar(keysym) : keysym & 0xFF00_0000 == 0x0100_0000 ? Unicode.Scalar(keysym & 0x00FF_FFFF) : nil
    }

    /// macOS virtual key codes (ANSI layout) by keysym; `shifted` for the
    /// upper symbol of a key.
    static func keyCode(for keysym: UInt32) -> (CGKeyCode, Bool)? {
        if let special = specials[keysym] { return (special, false) }
        guard keysym <= 0x7E, let scalar = Unicode.Scalar(keysym) else { return nil }
        let character = Character(scalar)
        if let code = plain[character] { return (code, false) }
        if let lower = character.lowercased().first, character.isUppercase, let code = plain[lower] { return (code, true) }
        if let base = shiftedSymbols[character], let code = plain[base] { return (code, true) }
        return nil
    }

    private static let specials: [UInt32: CGKeyCode] = [
        0xFF0D: 36, 0xFF8D: 76, 0xFF09: 48, 0x20: 49, 0xFF08: 51, 0xFF1B: 53, 0xFFFF: 117,
        0xFF51: 123, 0xFF53: 124, 0xFF54: 125, 0xFF52: 126, 0xFF50: 115, 0xFF57: 119, 0xFF55: 116, 0xFF56: 121,
        0xFFE1: 56, 0xFFE2: 60, 0xFFE3: 59, 0xFFE4: 62, 0xFFE9: 58, 0xFFEA: 61, 0xFFEB: 55, 0xFFEC: 54,
        0xFFE7: 55, 0xFFE8: 54, 0xFFE5: 57,
        0xFFBE: 122, 0xFFBF: 120, 0xFFC0: 99, 0xFFC1: 118, 0xFFC2: 96, 0xFFC3: 97, 0xFFC4: 98, 0xFFC5: 100,
        0xFFC6: 101, 0xFFC7: 109, 0xFFC8: 103, 0xFFC9: 111,
    ]

    private static let plain: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    private static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
}
#endif
