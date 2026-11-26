import AppKit
import CmuxNextUpdater

/// About cmux opens at once; "What's in this build" joins its credits when this build's signed notes
/// are read (cache-first, once per launch): an open panel is shown again with them, a later open has them.
@MainActor enum AboutPanelPullRequests {
    private static var list: BuildPullRequests?
    private static var load: Task<Void, Never>?

    static func show(updater: UpdaterService) {
        present()
        guard list == nil, load == nil else { return }
        load = Task { @MainActor in
            let read = await updater.currentBuildPullRequests()
            list = read
            guard !read.isEmpty, aboutPanelIsOpen else { return }
            present()
        }
    }

    private static func present() {
        let credits = AboutPanelCredits(bundle: .main, pullRequests: list).credits
        NSApp.orderFrontStandardAboutPanel(options: credits.map { [.credits: $0] } ?? [:])
    }

    /// AppKit's standard About panel (a private NSPanel subclass, "NSAboutPanel") is still on screen:
    /// a panel the person closed is not opened again.
    private static var aboutPanelIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.className.contains("About") }
    }
}
