public import Foundation

/// Main-actor work queued on the main run loop, to run on a later pass of it.
///
/// It replaces the hand-written `CFRunLoopPerformBlock(CFRunLoopGetMain(), mode)`, whose block
/// asserts the main actor with `assumeIsolated`, plus `CFRunLoopWakeUp(CFRunLoopGetMain())`: the
/// main-thread proof lives here once, and callers write a plain `@MainActor` closure.
///
/// Use it when the caller must return before the work runs, and the work must run in a
/// run-loop callout instead of inside a main-queue job (a menu's tracking loop started from
/// the callout lets main-actor jobs keep running while the menu is open). In the default
/// `.commonModes` the block also runs while a menu or a drag tracks events, where a
/// default-mode block would wait for the tracking to end.
///
/// ```swift
/// MainRunLoopBlock.perform { [weak self] in
///     self?.showExtensionsMenu()
/// }
/// ```
///
/// A block can be kept and queued again, for example once per request:
///
/// ```swift
/// let refresh = MainRunLoopBlock { [weak self] in self?.refresh() }
/// refresh.perform()
/// ```
public nonisolated struct MainRunLoopBlock: Sendable {
    private let body: @MainActor () -> Void

    /// Makes a block that runs `body` on the main actor each time it is performed.
    ///
    /// - Parameter body: The main-actor work. It runs once per ``perform(mode:)``.
    public init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    /// Queues the block on the main run loop and wakes the run loop, from any thread.
    ///
    /// The block runs on a later pass of the main run loop in `mode`, never inline: a caller
    /// on the main thread returns first. Each call runs the block once.
    ///
    /// - Parameter mode: The run loop mode to run in (default `.commonModes`, which includes
    ///   the default mode and the event-tracking mode of menus and drags).
    public func perform(mode: CFRunLoopMode = .commonModes) {
        let body = body
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, mode.rawValue) {
            // main-proof: a block queued on CFRunLoopGetMain() runs only on the main thread.
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(main)
    }

    /// Queues `body` on the main run loop once (``perform(mode:)`` of a new block).
    ///
    /// ```swift
    /// MainRunLoopBlock.perform { [weak self] in self?.popUp(menu) }
    /// ```
    ///
    /// - Parameters:
    ///   - mode: The run loop mode to run in (default `.commonModes`).
    ///   - body: The main-actor work.
    public static func perform(mode: CFRunLoopMode = .commonModes, _ body: @escaping @MainActor () -> Void) {
        MainRunLoopBlock(body).perform(mode: mode)
    }
}
