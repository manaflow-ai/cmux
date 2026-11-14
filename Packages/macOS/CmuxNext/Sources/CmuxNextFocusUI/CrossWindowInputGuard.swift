public import AppKit
import os

/// The last check before AppKit delivers a key-down (`CmuxApplication.sendEvent`): AppKit sends
/// every key to the key window, whatever window the key was typed into. When the key window
/// changed between the key press and its dispatch (a late `makeKey`, a key record that went stale,
/// a creation hold that runs its keys again later), a key typed into one cmux window would land in
/// another window. Such a key is dropped and logged, never delivered.
///
/// A window belongs to the cmux window that owns it (itself, a sheet, a Chromium page window, a
/// panel over it: the app's `WindowManager.owner(of:)`). A key reaches only the cmux window it was
/// typed into, with two exceptions for a window no cmux window owns (``dropsKey(eventWindow:keyWindow:heldRun:)``).
@MainActor
public struct CrossWindowInputGuard {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.cross-window")

    /// The cmux window id that owns a window, nil for a window no cmux window owns.
    public let owner: @MainActor (NSWindow) -> String?

    public init(owner: @escaping @MainActor (NSWindow) -> String?) { self.owner = owner }

    /// One run of a creation hold's held keys again (``dropsKey(eventWindow:keyWindow:heldRun:)``): the key window when
    /// the run began. A window that became key since, during the run, was made key by one of its own keys.
    public struct HeldRun {
        public weak var keyWindow: NSWindow?
        public init(keyWindow: NSWindow?) { self.keyWindow = keyWindow }
    }

    /// True when a key typed into `eventWindow` would reach `keyWindow`, a window outside the cmux window it was typed
    /// into: another cmux window always; a window no cmux window owns (a floating panel such as the Quick Agent Chat or
    /// the Chief pet's reply box) only for a held key (`heldRun`) whose run began while that window was key. A window keeps
    /// its first responder when it stops being key, so a line held for a terminal went into a panel the person opened
    /// during the hold, and its Return sent it to an agent (review of #35275; the dogfood v2.2.3 class). A key typed now may
    /// reach a panel that became key after it was typed (the person opened it and typed into it at once), and so may a held
    /// key after an earlier key of its own run made the panel key (Start Agent's key, then its line: review of #35832). Not
    /// judged: a key with no window, a key typed into a window no cmux window owns, no key window.
    public func dropsKey(eventWindow: NSWindow?, keyWindow: NSWindow?, heldRun: HeldRun? = nil) -> Bool {
        guard let eventWindow, let keyWindow, eventWindow !== keyWindow, let source = owner(eventWindow) else { return false }
        guard let target = owner(keyWindow) else { return heldRun.map { $0.keyWindow === keyWindow } ?? false }
        return target != source
    }

    /// ``dropsKey(eventWindow:keyWindow:heldRun:)``, logging a drop: the check `CmuxApplication.sendEvent` runs before AppKit
    /// delivers a key-down (the app's `CrossWindowInputGuard.drops(keyTypedInto:keyWindow:router:)`).
    public func dropsAndLogsKey(eventWindow: NSWindow?, keyWindow: NSWindow?, heldRun: HeldRun?) -> Bool {
        guard dropsKey(eventWindow: eventWindow, keyWindow: keyWindow, heldRun: heldRun) else { return false }
        let source = eventWindow.flatMap(owner) ?? "-"
        guard let target = keyWindow.flatMap(owner) else {
            Self.logger.error("dropped a held key of window \(source, privacy: .public): a window no cmux window owns was key when its run began")
            return true
        }
        #if DEBUG
        Self.logger.fault("dropped a key typed into window \(source, privacy: .public) that would reach window \(target, privacy: .public)")
        #else
        Self.logger.error("dropped a key typed into window \(source, privacy: .public) that would reach window \(target, privacy: .public)")
        #endif
        return true
    }
}
