package import CmuxNextLaunch
package import Foundation

/// The agent chats' saved files a launch draws or keeps, read and decoded off the main thread from
/// the top of `main` (#17587): the pages' last images (``AgentPaneLaunchImages``), the new chats'
/// unsent drafts (``AgentUnsentDrafts``) and the chats' composer states (``AgentPaneRelaunchWake``:
/// the list only; each chat reads its chips' contents when its page asks). The agent tab store, made
/// on the main thread in `applicationDidFinishLaunching`, only takes them.
package nonisolated struct AgentPaneLaunchReads: Sendable {
    /// The pages' last images, decoded by the reader and handed over without a wait.
    package let pageImages: SavedFrameDirectory
    /// The new chats' unsent drafts, by tab.
    package let unsentDrafts: LaunchRead<[String: String]>
    /// The last quit's composer states, by tab, without their chips' contents (``AgentPaneWakeState/kept``):
    /// the file is gone once read.
    package let wakeStates: LaunchRead<[String: AgentPaneWakeState]>

    /// Starts every read now.
    /// - Parameters:
    ///   - state: The build's state directory, where the files are saved.
    ///   - readOnMain: Hears `launch_read_on_main.<file>` when a take waited on the main thread.
    package init(state: URL, readOnMain: @escaping @Sendable (String) -> Void) {
        pageImages = SavedFrameDirectory(url: AgentPaneLaunchImages.directory(beside: state),
                                         maximumBytes: AgentPaneLaunchImages.maximumBytes, name: "agent_page_images")
        let draftsFile = AgentUnsentDrafts.file(in: state)
        unsentDrafts = LaunchRead("unsent_drafts", readOnMain: readOnMain) { AgentUnsentDrafts.read(draftsFile) }
        let wakeFile = AgentPaneRelaunchWake.file(in: state)
        wakeStates = LaunchRead("agent_wake_states", readOnMain: readOnMain) { AgentPaneRelaunchWake.takeSaved(from: wakeFile) }
    }
}
