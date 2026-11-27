public import AppKit
public import CmuxNextActions
public import CmuxNextDaemonService
public import CmuxNextSettings
public import CmuxNextUpdater

/// What the background ready copy (``BackgroundReadyController``) reads and asks of the App. The App's
/// services conform: the settings, background mode, the registry, the updater and the menu bar item are
/// theirs as they are; the rest are one-line forwards to the window manager and the quit.
@MainActor
public protocol BackgroundReadyHost: AnyObject, Sendable {
    var settings: SettingsController? { get }
    var background: BackgroundActivation { get }
    var registry: ActionRegistry { get }
    var updater: UpdaterService { get }
    var menuBarExtra: MenuBarExtra { get }
    /// The shell windows on screen, in any order.
    var backgroundReadyShownWindows: [NSWindow] { get }
    /// The id of shell window `window`; nil when it is no live shell window (it closed).
    func backgroundReadyWindowID(_ window: NSWindow) -> String?
    /// The front shell window has the keys.
    var backgroundReadyFrontIsKey: Bool { get }
    /// The front pane's chat has painted; nil when the front pane is not a chat.
    var backgroundReadyFrontChatPainted: Bool? { get }
    /// The quit's saves that end nothing: the windows' frames into the registry, then the window records, the
    /// sidebar, Home's cache and the launch record.
    func backgroundReadyCaptureGeometry()
    func backgroundReadySaveWindowRecords() async
    func backgroundReadySaveSidebar() async
    func backgroundReadySaveHomeCache() async
    func backgroundReadySaveLaunchRecord() async
    /// Reopens closed window `id` as Reopen Closed does.
    func backgroundReadyReopen(windowID: String)
    /// A Dock click with nothing hidden: a window comes forward, else one reopens or opens.
    func backgroundReadyReopenOrCreate()
    /// A hidden start's first show: the launch's window restore.
    func backgroundReadyRestore()
    /// This launch is a safe restart (two quick unexpected ends): Chromium starts only when a page needs it.
    var backgroundReadyIsSafeRestart: Bool { get }
    /// A hidden start's first show: the Chromium warm-up the launch skipped.
    func backgroundReadyStartChromiumWarmup()
    /// Tells `listener` each agent pane launch mark's name, on the marking thread (`agent_pane.painted`).
    func backgroundReadyListenForLaunchMarks(_ listener: @escaping @Sendable (String) -> Void)
    /// Starts AppKit's termination with `origin`.
    func backgroundReadyRequestQuit(_ origin: QuitOrigin)
}
