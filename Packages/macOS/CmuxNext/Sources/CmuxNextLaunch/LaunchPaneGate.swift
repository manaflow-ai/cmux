public import CmuxNextWakeups

/// While the app launches, only the panes on screen make their content (feature
/// `launchVisiblePanesOnly`): a pane the layout reports off screen, in the keep-alive band or away,
/// makes no terminal surface, page or engine until startup completes, and the focused pane's content
/// comes before the other visible panes'. Hidden workspaces build no controller at all (a window
/// builds only the workspace it shows). Chrome's session restore does the same: it loads the active
/// tab of each window first and the background tabs only once startup is done, and leaves a tab that
/// is never shown unloaded (chrome/browser/sessions/tab_loader.cc, `TabLoader::StartLoading` and
/// `TabLoader::ShouldStopLoadingTabs`).
///
/// ``viewsBuilt`` counts the pane content views made before startup completed; at completion it is
/// sent once as the value mark ``viewsBuiltMark`` (bench-startup.py's `VALUE_MARKS`), whose
/// acceptance is "views built == visible panes". It goes out before `startup_complete`
/// (``StartupScheduler/whenCompleteFirst(_:)``), so a bench run that waits for that mark has it.
///
/// The app makes one at its composition root with the launch's ``StartupScheduler`` when the feature
/// is on, and with none otherwise (then it holds nothing and counts nothing).
///
/// ```swift
/// let gate = LaunchPaneGate(startup: features.isEnabled(.launchVisiblePanesOnly) ? launchStartup : nil)
/// if gate.holdsPanes, !paneIsOnScreen { gate.afterStartup { pane.showSelectionNow() }; return }
/// gate.noteBuilt()
/// ```
@MainActor
public final class LaunchPaneGate {
    /// The value mark of ``viewsBuilt`` at completion.
    public nonisolated static let viewsBuiltMark = "launch.views_built"

    /// Pane content views made while the gate held panes.
    public private(set) var viewsBuilt = 0
    private let startup: StartupScheduler?

    /// - Parameters:
    ///   - startup: The launch's scheduler; nil holds nothing (the feature off, a scheduler-less test).
    ///   - report: Gets ``viewsBuilt`` once, at completion; by default the value mark to the bench's pipe.
    public init(startup: StartupScheduler?,
                report: @escaping @MainActor (Int) -> Void = { LaunchMarkSink.shared.writeValue(name: LaunchPaneGate.viewsBuiltMark, value: UInt64($0)) }) {
        self.startup = startup
        // A gate made after completion measured nothing: it reports nothing.
        guard let startup, startup.completion == nil else { return }
        startup.whenCompleteFirst { [weak self] _ in
            guard let self else { return }
            report(viewsBuilt)
        }
    }

    /// Whether panes off screen wait now: from launch until startup completes, never once quit began.
    public var holdsPanes: Bool {
        guard let startup else { return false }
        return startup.completion == nil && startup.log.phase != .quitting
    }

    /// Runs `body` once startup completed, in its own afterStartup post: one main task per frame,
    /// behind pending input, so the panes that waited never all build in one turn. Nothing runs
    /// after quit began.
    public func afterStartup(_ body: @escaping @MainActor @Sendable () -> Void) {
        startup?.post(.afterStartup, "LaunchPaneGate.afterStartup", on: .main, body)
    }

    /// A pane made its content view now: counted while the gate holds panes.
    public func noteBuilt() {
        if holdsPanes { viewsBuilt += 1 }
    }
}
