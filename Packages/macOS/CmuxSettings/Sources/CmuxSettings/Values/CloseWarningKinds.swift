import Foundation

/// The close-warning toggles behind a close confirmation dialog.
///
/// A dialog's "Don't ask again" checkbox turns off exactly these toggles, so
/// the same close would not ask the next time.
public struct CloseWarningKinds: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `app.warnBeforeClosingTab`: tabs that would lose a running process.
    public static let tab = CloseWarningKinds(rawValue: 1 << 0)

    /// `app.warnBeforeClosingTabXButton`: every close from a tab's X button.
    public static let tabCloseButton = CloseWarningKinds(rawValue: 1 << 1)

    /// `app.warnBeforeClosingWorkspace`: the "Close workspace?" prompts.
    public static let workspace = CloseWarningKinds(rawValue: 1 << 2)

    /// `app.warnBeforeClosingWindow`: the "Close window?" prompts.
    public static let window = CloseWarningKinds(rawValue: 1 << 3)

    /// An active foreground process requires a warning regardless of settings.
    public static let safety = CloseWarningKinds(rawValue: 1 << 4)
}
