public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

/// Input while the first window shows its launch picture (p08-startup-061): the edges of the picture phase reach the
/// key router's stand-in buffer (``LaunchPictureKeys``), and the window's ``LaunchPictureCover`` holds a click on the
/// picture (``LaunchPictureCover/Clicks``).
/// - `launch_picture_shown` (this init): the buffer begins for the window; a key or a click raises the build of the
///   window's content to the next frame (a userBlocking post, never in the input's turn).
/// - The pane region's first content: the buffer gives the waiting keys to their terminals.
/// - The picture left (every region drew, the bound, a resize; ``finish``): the buffer ends for the window, in its
///   own turn (the picture can leave inside the root's layout, where no key is delivered).
///
/// ```swift
/// let input = LaunchPictureInput(window: id, shell: window, keys: keys, reveal: reveal, mainWork: mainWork,
///                                pastFirstFrame: { startup.log.phase != .beforeFirstFrame }, build: build) { shownModel() }
/// cover = LaunchPictureCover(..., clicks: input.clicks, onFinish: input.finish)
/// ```
@MainActor
public struct LaunchPictureInput {
    public let clicks: LaunchPictureCover.Clicks
    public let finish: @MainActor () -> Void

    /// - Parameters:
    ///   - window: The window's stable id (`WindowState.id`).
    ///   - shell: The window showing the picture.
    ///   - keys: The key router's stand-in buffer.
    ///   - reveal: The launch's regions.
    ///   - mainWork: The app's main-thread scheduler.
    ///   - pastFirstFrame: Whether the launch's first frame is committed: before it, the build's afterFirstFrame post
    ///     is the earliest a key or a click can raise it to.
    ///   - build: Builds the window's content under the picture; it does nothing once it ran.
    ///   - stamp: What the window shows in the model now (its workspace or page): a held click whose stamp changed
    ///     before its part went live is dropped.
    public init(window: String, shell: NSWindow?, keys: LaunchPictureKeys, reveal: LaunchReveal, mainWork: MainWorkScheduler,
                pastFirstFrame: @escaping @MainActor () -> Bool, build: @escaping @MainActor @Sendable () -> Void,
                stamp: @escaping @MainActor () -> String?) {
        let raise: @MainActor () -> Void = {
            guard pastFirstFrame() else { return }
            mainWork.post(.userBlocking, owner: "LaunchPictureInput.raise", build)
        }
        keys.begin(window: window, shell: shell) { _ in raise() }
        reveal.whenProduced(.pane) { [weak keys] in keys?.retry() }
        clicks = LaunchPictureCover.Clicks(stamp: stamp, raise: { _ in raise() })
        finish = { [weak keys] in
            mainWork.post(.userBlocking, owner: "LaunchPictureInput.finish") { keys?.end(window: window) }
        }
    }
}
