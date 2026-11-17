public import CmuxNextDesign
public import CmuxNextHome

/// Stage 0's stand-in box contents and swap signal, for the app's composition root.
public typealias LaunchBareHandoff = HomeLaunchBareHandoff

extension LaunchShellContent {
    /// Stage 0's bare content (``HomeLaunchBare``, a stand-in Home) with the Chief's name
    /// (`HomeStrings.chiefName`), for `LaunchShell.content`.
    /// - Parameters:
    ///   - handoff: Where the stand-in's box contents park and Home's swap signal (Home gets the same one).
    ///   - mark: The app's launch marks (`DebugTimings.markLaunch`).
    public static func bareHome(_ handoff: HomeLaunchBareHandoff, mark: @escaping (String) -> Void) -> LaunchShellContent {
        HomeLaunchBare.content(title: HomeStrings.chiefName, handoff: handoff, mark: mark)
    }
}
