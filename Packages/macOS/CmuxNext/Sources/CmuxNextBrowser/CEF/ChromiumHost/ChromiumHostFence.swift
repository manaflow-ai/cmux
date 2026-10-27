import AppKit
import Darwin
import QuartzCore

/// One turn's fence of a window's Core Animation context: this process's send right to the port
/// `-[CAContext createFencePort]` made. ``ChromiumHostResizeFence`` releases the right at the turn's
/// commit (``releaseOwnRight()``); the port lives on while the host or the fork holds a copy.
final class ChromiumHostFence {
    /// The send right a resize sends a copy of.
    let port: mach_port_t
    private let holdCommit: (mach_port_t) -> Void
    private let invalidate: () -> Void
    private let release: (mach_port_t) -> Void
    private var held = false
    private var ended = false
    private(set) var released = false

    /// - Parameters:
    ///   - port: A send right this fence owns.
    ///   - hold: Holds the context's next commit on `port` (`-setFencePort:`).
    ///   - invalidate: Ends every fence of the context now (`-invalidateFences`).
    ///   - release: Drops a send right (`mach_port_deallocate`; tests record it).
    init(port: mach_port_t, hold: @escaping (mach_port_t) -> Void, invalidate: @escaping () -> Void,
         release: @escaping (mach_port_t) -> Void = { _ = mach_port_deallocate(mach_task_self_, $0) }) {
        self.port = port
        holdCommit = hold
        self.invalidate = invalidate
        self.release = release
    }

    /// Holds the context's commit on the port, once: true the first time.
    func hold() -> Bool {
        guard !held, !released else { return false }
        held = true
        holdCommit(port)
        return true
    }

    /// Ends every fence of the context, once: a page late for its deadline shows its last frame. True
    /// the first time; a later call would end a newer turn's fence of the context too.
    @discardableResult
    func endAll() -> Bool {
        guard !ended else { return false }
        ended = true
        invalidate()
        return true
    }

    /// Drops this process's right, once.
    func releaseOwnRight() {
        guard !released else { return }
        released = true
        release(port)
    }
}

/// A window's fences from its Core Animation context, through the QuartzCore calls WebKit uses
/// (Source/WebCore/PAL/pal/spi/cocoa/QuartzCoreSPI.h: `+allContexts`, `-layer`, `-createFencePort`,
/// `-setFencePort:`, `-invalidateFences`). The context is the one whose layer is the root of the
/// window's layer tree. Each message is sent only after `responds(to:)` proved the receiver has it,
/// so an OS without one makes no fence, and every resize goes unfenced.
struct ChromiumHostContextFences: ChromiumHostFenceMaking {
    func makeFence(for window: NSWindow) -> ChromiumHostFence? {
        guard let context = Self.context(of: window) else { return nil }
        let port = context.createFencePort()
        guard port != 0 else { return nil }
        return ChromiumHostFence(port: port, hold: { context.setFencePort($0) }, invalidate: { context.invalidateFences() })
    }

    private static func context(of window: NSWindow) -> (any QuartzFenceSPI)? {
        var root = window.contentView?.layer
        while let up = root?.superlayer { root = up }
        guard let root, let contextClass: AnyClass = NSClassFromString("CAContext"),
              (contextClass as AnyObject).responds(to: #selector(QuartzFenceSPI.allContexts)),
              let contexts = (contextClass as AnyObject).perform(#selector(QuartzFenceSPI.allContexts))?
                  .takeUnretainedValue() as? [NSObject] else { return nil }
        for context in contexts {
            // One check per selector, not one `&&`: its autoclosure would capture the non-Sendable context.
            guard context.responds(to: #selector(getter: QuartzFenceSPI.layer)) else { continue }
            guard context.responds(to: #selector(QuartzFenceSPI.createFencePort)) else { continue }
            guard context.responds(to: #selector(QuartzFenceSPI.setFencePort(_:))) else { continue }
            guard context.responds(to: #selector(QuartzFenceSPI.invalidateFences)) else { continue }
            let spi = unsafeBitCast(context, to: (any QuartzFenceSPI).self)
            if spi.layer === root { return spi }
        }
        return nil
    }
}

/// The QuartzCore SPI of a context's fences. No class conforms; ``ChromiumHostContextFences`` casts
/// a `CAContext` it asked `responds(to:)` for every message.
@objc private protocol QuartzFenceSPI {
    /// `+[CAContext allContexts]`: an instance requirement because `#selector` cannot name a static
    /// one of a protocol; it is sent to the class object with `perform(_:)`.
    func allContexts() -> [NSObject]?
    var layer: CALayer? { get }
    func createFencePort() -> mach_port_t
    func setFencePort(_ port: mach_port_t)
    func invalidateFences()
}
