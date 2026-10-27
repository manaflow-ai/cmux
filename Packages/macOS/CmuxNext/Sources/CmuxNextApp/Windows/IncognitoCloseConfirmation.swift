import AppKit
import CmuxNextDaemon
import CmuxNextWakeups

/// Closing an incognito window closes its workspaces and ends their
/// terminals (coordinator decision 2026-09-30). Quitting with one open asks
/// in the quit alert instead (`QuitAlert`, one alert, not two).
/// It asks first only while a terminal runs a program other than the shell,
/// the rule Close Workspace uses (`DestructiveConfirmation`); otherwise it
/// closes at once.
enum IncognitoCloseConfirmation {
    /// The question for these running programs, or nil to close at once.
    static func prompt(programs: [String]) -> DestructiveConfirmation.Prompt? {
        guard !programs.isEmpty else { return nil }
        return DestructiveConfirmation.Prompt(
            title: ConfirmationStrings.closeIncognitoWindowTitle,
            body: ConfirmationStrings.stillRunning(programs.joined(separator: ", ")),
            button: ConfirmationStrings.close
        )
    }

    /// Foreground programs in the workspaces of `windowIDs` (sorted, unique).
    static func runningPrograms(inWindows windowIDs: [String], _ services: AppServices) async -> [String] {
        let registry = services.windows.registry.value
        var programs: Set<String> = []
        for id in windowIDs.flatMap({ registry.window($0)?.workspaceIDs ?? [] }) {
            guard let (workspace, daemon) = services.machines.workspace(id: id) else { continue }
            programs.formUnion(await DestructiveConfirmation.runningPrograms(in: workspace, on: daemon))
        }
        return programs.sorted()
    }

    /// Asks (a sheet on `window`) when the windows run programs; calls
    /// `done(true)` to go ahead.
    static func confirm(windows windowIDs: [String], sheetOn window: NSWindow?, _ services: AppServices,
                        done: @escaping @MainActor @Sendable (Bool) -> Void) {
        let mainWork = services.mainWork
        // The person's close: the terminals are asked off main, the answer shows as one visible task.
        services.work.task(.userBlocking) { [weak window] in
            let programs = await IncognitoCloseConfirmation.runningPrograms(inWindows: windowIDs, services)
            mainWork.postFromAnyThread(.visible, owner: "IncognitoCloseConfirmation.confirm") { [weak window] in
                guard let prompt = IncognitoCloseConfirmation.prompt(programs: programs) else { return done(true) }
                DestructiveConfirmation.present(prompt, in: window) { done($0) }
            }
        }
    }
}
