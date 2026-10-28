import Foundation

/// One call of the fork's lock delegate (`cmux_shim_lock_event_t`, task 227): what the fn of
/// `cmux_shim_set_lock_handler` gets, with the page's browser and a detail.
nonisolated enum ChromiumHostLockEvent: Int32, Sendable {
    /// The page called `requestPointerLock()`; detail 1 asks for unadjusted movement.
    case pointerLockRequested = 0
    /// The page's pointer lock ended (its page, Chromium or cmux ended it).
    case pointerUnlocked = 1
    /// The page called `navigator.keyboard.lock()`; detail 1 when the lock takes Escape too.
    case keyboardLockRequested = 2
    /// The page's keyboard lock ended.
    case keyboardUnlocked = 3
}

/// The shim's lock calls (fork API 31, task 227; host mode, task 229): cmux's lock fn, its answers,
/// its exits and the locked movement. Each returns 0 when the browser is gone or the fork lacks API
/// 31; in host mode the answers, exits and moves are posts (1 once sent), and the handler goes to a
/// host whose HELLO lists the lock delegate (ChromiumHost/src/host_locks.h).
nonisolated struct CEFShimLockOps {
    /// `cmux_shim_set_lock_handler`'s fn: context, event (``ChromiumHostLockEvent``), browser, detail.
    typealias Handler = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Void

    /// handler (NULL removes it), context -> 1 when the fork took it.
    let setHandler: @convention(c) (Handler?, UnsafeMutableRawPointer?) -> Int32
    /// browser, allowed.
    let pointerLockAnswer: @convention(c) (Int32, Int32) -> Int32
    /// browser, allowed.
    let keyboardLockAnswer: @convention(c) (Int32, Int32) -> Int32
    /// browser, by user (Chrome's cooldown for the page).
    let exitPointerLock: @convention(c) (Int32, Int32) -> Int32
    let exitKeyboardLock: @convention(c) (Int32) -> Int32
    /// browser, dx, dy (DIP), `cef_event_flags_t` modifiers with the held buttons' bits.
    let sendLockedMouseMove: @convention(c) (Int32, Double, Double, Int32) -> Int32

    init(_ r: CEFShimLibrary.Resolver) throws(CEFShimLibrary.LoadError) {
        unsafe setHandler = try r("cmux_shim_set_lock_handler")
        pointerLockAnswer = try r("cmux_shim_browser_pointer_lock_answer")
        keyboardLockAnswer = try r("cmux_shim_browser_keyboard_lock_answer")
        exitPointerLock = try r("cmux_shim_browser_exit_pointer_lock")
        exitKeyboardLock = try r("cmux_shim_browser_exit_keyboard_lock")
        sendLockedMouseMove = try r("cmux_shim_browser_send_locked_mouse_move")
    }
}
