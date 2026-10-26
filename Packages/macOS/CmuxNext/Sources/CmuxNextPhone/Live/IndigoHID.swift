import CoreGraphics
import Darwin

/// SimulatorKit's legacy Indigo message builders (`IndigoHIDMessageFor*`), each
/// returning a message this side owns. A builder this Xcode lacks is nil.
@MainActor
struct IndigoBuilders {
    private typealias Mouse = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32)
        -> UnsafeMutableRawPointer?
    private typealias Keyboard = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias Arbitrary = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias Button = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?

    /// A touch at a 0...1 point: down or drag, or up.
    var mouse: ((CGPoint, _ up: Bool) -> IndigoMessage)?
    var keyboard: ((_ usage: UInt32, _ down: Bool) -> IndigoMessage)?
    /// Arbitrary HID (volume) on the digitizer target.
    var arbitrary: ((_ page: UInt32, _ usage: UInt32, _ down: Bool) -> IndigoMessage)?
    /// An Indigo event source button (home, lock, Siri, the software keyboard toggle).
    var button: ((_ source: Int32, _ down: Bool) -> IndigoMessage)?

    /// Every builder returns a malloc'd message or nil and keeps no pointer it was given.
    /// 0x32 is the digitizer target, 0x33 the button target; 1 = down (or drag), 2 = up.
    init(_ runtime: SimulatorKitRuntime) {
        // SAFETY: only resolves the function; see the call inside.
        if let build = unsafe runtime.function("IndigoHIDMessageForMouseNSEvent", as: Mouse.self) {
            mouse = { point, up in
                var point = point
                // SAFETY: the builder reads the one CGPoint at &point (a local) during the call;
                // the second point is nil. IndigoMessage owns what it returns.
                return unsafe IndigoMessage(build(&point, nil, 0x32, up ? 2 : 1, 1, 1, 0))
            }
        }
        // SAFETY: only resolves the function; see the call inside.
        if let build = unsafe runtime.function("IndigoHIDMessageForKeyboardArbitrary", as: Keyboard.self) {
            // SAFETY: scalar arguments only; IndigoMessage owns what it returns.
            keyboard = { usage, down in unsafe IndigoMessage(build(usage, down ? 1 : 2)) }
        }
        // SAFETY: only resolves the function; see the call inside.
        if let build = unsafe runtime.function("IndigoHIDMessageForHIDArbitrary", as: Arbitrary.self) {
            // SAFETY: scalar arguments only; IndigoMessage owns what it returns.
            arbitrary = { page, usage, down in unsafe IndigoMessage(build(0x32, page, usage, down ? 1 : 2)) }
        }
        // SAFETY: only resolves the function; see the call inside.
        if let build = unsafe runtime.function("IndigoHIDMessageForButton", as: Button.self) {
            // SAFETY: scalar arguments only; IndigoMessage owns what it returns.
            button = { source, down in unsafe IndigoMessage(build(source, down ? 1 : 2, 0x33)) }
        }
    }
}

/// One Indigo HID message as a builder returns it: nil, or a malloc'd block
/// this side owns until `sendWithMessage:freeWhenDone:YES` takes it, freed on
/// every other path (Chromium's `std::unique_ptr<T, base::FreeDeleter>`,
/// base/memory/free_deleter.h).
// SAFETY: the pointer is private, and no API gives it out except the consuming handOff(), so
// one IndigoMessage is the only owner of its block until that call ends its life.
@safe
struct IndigoMessage: ~Copyable {
    private let bytes: UnsafeMutableRawPointer?

    /// Owns `built`, which must be nil or a malloc'd block nobody else owns.
    init(_ built: UnsafeMutableRawPointer?) {
        // SAFETY: stores the pointer only; it is freed once, in deinit, or handed off.
        unsafe bytes = built
    }

    /// The message for a callee that frees it; this side no longer owns it.
    consuming func handOff() -> UnsafeMutableRawPointer? {
        // SAFETY: copies the address only; the block is not read or freed here.
        let handed = unsafe bytes
        discard self
        // SAFETY: `discard self` stopped deinit, so only the callee that takes `handed` frees it.
        return unsafe handed
    }

    deinit {
        // SAFETY: a message not handed off (handOff discards self) is still this side's
        // malloc'd block, or nil, so it is freed exactly once, here.
        unsafe free(bytes)
    }
}
