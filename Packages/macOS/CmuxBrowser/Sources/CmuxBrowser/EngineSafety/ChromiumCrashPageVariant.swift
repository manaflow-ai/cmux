public import Foundation

/// Which crashed-page wording a Chromium pane shows, following Chrome's sad
/// tab: "Aw, Snap!" for a crash, and "Can't open this page" when the same
/// pane crashes again within `repeatWindow` of its last crash.
public struct ChromiumCrashPageVariant: Equatable, Sendable {
    /// Whether this is a repeat crash ("Can't open this page").
    public var isRepeat: Bool
    /// Whether the process ran out of memory (the repeat body suggests
    /// freeing memory).
    public var isOutOfMemory: Bool
    /// The error code text ("SIGSEGV", "exit 3"), if known.
    public var errorCode: String?

    public static let repeatWindow: TimeInterval = 10

    public init(isRepeat: Bool, isOutOfMemory: Bool, errorCode: String?) {
        self.isRepeat = isRepeat
        self.isOutOfMemory = isOutOfMemory
        self.errorCode = errorCode
    }

    /// The variant for `exit` at `now`, given the pane's previous crash.
    public init(exit: BrowserPageProcessExit, at now: Date, previousCrash: Date?) {
        let isRepeat = previousCrash.map { now.timeIntervalSince($0) < Self.repeatWindow } ?? false
        self.init(isRepeat: isRepeat, isOutOfMemory: exit.kind == .outOfMemory, errorCode: exit.codeDescription)
    }
}
