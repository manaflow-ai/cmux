public import CmuxNextWakeups

/// The warm-ups that make a launch's first opens cost what later opens cost: the palette's
/// panel and command page, then the icon picker, then the system file picker. Each is one
/// afterStartup main post of the launch's ``StartupScheduler`` (one per palette step), so they
/// run in this order, one per idle frame behind input, once each visible pane showed its
/// content: never between the first window and its first terminal or agent page frame (cx-z9kz0).
/// Chrome defers the same kind of warm-up with `AfterStartupTaskUtils::PostTask`
/// (chrome/browser/after_startup_task_utils.cc).
///
/// The work is injected, so tests post it on their own scheduler.
///
/// ```swift
/// LaunchFirstOpenWarmups(paletteSteps: PaletteController.prepareStepNames,
///                        preparePalette: { _ = palette.prepare(step: $0) },
///                        prepareIconPicker: { iconPicker.prepare() },
///                        warmOpenPanel: { openPanel.warmWhenIdle() }).post(on: order.startup)
/// ```
public struct LaunchFirstOpenWarmups {
    /// One name per palette step (`PaletteController.prepareStepNames`).
    public let paletteSteps: [StaticString]
    /// Runs one palette step (`PaletteController.prepare(step:)`).
    public let preparePalette: @MainActor @Sendable (Int) -> Void
    /// Makes the icon picker's panel, page and symbol catalog (`IconPickerService.prepare`).
    public let prepareIconPicker: @MainActor @Sendable () -> Void
    /// Starts the made-ahead file picker's idle warm-up (`MadeAheadOpenPanel.warmWhenIdle`).
    public let warmOpenPanel: @MainActor @Sendable () -> Void

    /// - Parameters:
    ///   - paletteSteps: One name per palette step.
    ///   - preparePalette: Runs one palette step by index.
    ///   - prepareIconPicker: Makes the icon picker ahead of its first open.
    ///   - warmOpenPanel: Starts the file picker's idle warm-up.
    public init(paletteSteps: [StaticString], preparePalette: @escaping @MainActor @Sendable (Int) -> Void,
                prepareIconPicker: @escaping @MainActor @Sendable () -> Void, warmOpenPanel: @escaping @MainActor @Sendable () -> Void) {
        self.paletteSteps = paletteSteps
        self.preparePalette = preparePalette
        self.prepareIconPicker = prepareIconPicker
        self.warmOpenPanel = warmOpenPanel
    }

    /// Posts each warm-up, in order.
    public func post(on startup: StartupScheduler) {
        for (step, name) in paletteSteps.enumerated() {
            startup.post(.afterStartup, name, on: .main) { [preparePalette] in preparePalette(step) }
        }
        startup.post(.afterStartup, "IconPicker.prepare", on: .main, prepareIconPicker)
        startup.post(.afterStartup, "OpenPanel.warmWhenIdle", on: .main, warmOpenPanel)
    }
}
