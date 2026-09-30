import AppKit
import CmuxNextDaemon

/// Closing an incognito window, or quitting with one open, closes its
/// workspaces and ends their terminals (coordinator decision 2026-09-30).
/// It asks first only while a terminal runs a program other than the shell,
/// the rule Close Workspace uses (`DestructiveConfirmation`); otherwise it
/// closes at once.
enum IncognitoCloseConfirmation {
    /// The question for these running programs, or nil to close at once.
    static func prompt(programs: [String], quitting: Bool) -> DestructiveConfirmation.Prompt? {
        guard !programs.isEmpty else { return nil }
        return DestructiveConfirmation.Prompt(
            title: quitting ? ConfirmationStrings.quitIncognitoTitle : ConfirmationStrings.closeIncognitoWindowTitle,
            body: ConfirmationStrings.incognitoBody(programs.joined(separator: ", ")),
            button: quitting ? ConfirmationStrings.quit : ConfirmationStrings.close
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
    static func confirm(windows windowIDs: [String], quitting: Bool, sheetOn window: NSWindow?, _ services: AppServices,
                        done: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in
            let programs = await runningPrograms(inWindows: windowIDs, services)
            guard let prompt = prompt(programs: programs, quitting: quitting) else { return done(true) }
            DestructiveConfirmation.present(prompt, in: window) { done($0) }
        }
    }
}
