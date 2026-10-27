public import CmuxNextWakeups

/// Builds Ghostty configs where blocking is allowed and hands each result to the main actor once: Chrome's
/// `PostTaskAndReplyWithResult` with `MayBlock` (base/task/thread_pool.h). libghostty's config load reads the
/// config files, their includes and the theme file, so it never runs on the main thread.
///
/// The app passes ``GhosttyLaneConfigLoader`` (``GhosttyRuntime/start(loadingOn:then:)``); tests pass their own.
public protocol GhosttyConfigLoading {
    /// Runs `build` off the main thread, then `apply` on the main actor with its result.
    ///
    /// - Parameters:
    ///   - build: The config build (`GhosttyConfigInputs.buildConfig`); it may block.
    ///   - apply: Takes the built config (and with it the duty to apply or free it).
    func load(_ build: @escaping @Sendable () -> GhosttyBuiltConfig?,
              apply: @escaping @MainActor @Sendable (GhosttyBuiltConfig?) -> Void)
}

/// The app's loader: the build runs on `work`'s files lane at `.userBlocking` (a person waits for the theme or
/// the terminal it changes), and the reply is one `.visible` main task.
public struct GhosttyLaneConfigLoader: GhosttyConfigLoading {
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - work: The app's blocking-work lanes.
    ///   - mainWork: The main-thread scheduler the reply is posted to.
    public init(work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.work = work
        self.mainWork = mainWork
    }

    public func load(_ build: @escaping @Sendable () -> GhosttyBuiltConfig?,
                     apply: @escaping @MainActor @Sendable (GhosttyBuiltConfig?) -> Void) {
        work.run(.userBlocking, mayBlock: .files, build)
            .reply(on: mainWork, class: .visible, owner: "terminal.ghosttyConfig", apply)
    }
}
