import CmuxNextTerminal

/// Connects the terminal module's process-wide hooks to the app's services
/// at launch: app-scoped Ghostty actions (`appActionHandler`) and the
/// menu-first rule of a terminal's key equivalents (`menuMayClaim`).
struct TerminalHooks {
    weak var services: AppServices?

    func install() {}
}
