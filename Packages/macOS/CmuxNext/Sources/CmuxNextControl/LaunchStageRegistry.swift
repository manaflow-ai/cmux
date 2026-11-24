/// The three launch stages from `docs/design/launch-shell-first.md`.
public enum LaunchStage: UInt8, Sendable {
    case shell = 0
    case visible = 1
    case rest = 2
}

public struct LaunchTask: Sendable, Equatable {
    public let name: String
    public let stage: LaunchStage

    public init(_ name: String, _ stage: LaunchStage) {
        self.name = name
        self.stage = stage
    }
}

/// The launch task inventory is intentionally explicit metadata for the current
/// launch plan. Adding a stage-0 declaration outside the shell operations makes
/// the registry test fail; this registry does not instrument runtime call sites.
public struct LaunchStageRegistry {
    public init() {}
    public static let stageZeroAllowlist: Set<String> = [
        "read_launch_record", "make_window", "put_saved_image", "commit_first_frame", "finish_launching",
    ]

    /// The work currently performed by ``AppDelegate.finishLaunching``. Existing
    /// behavior is unchanged; these declarations make the intended stage plan
    /// reviewable until the first-frame reorder wires each task to a phase.
    public static let finishLaunching: [LaunchTask] = [
        .init("read_launch_record", .shell), .init("make_window", .shell),
        .init("put_saved_image", .shell), .init("commit_first_frame", .shell), .init("finish_launching", .shell),
        .init("prestart_daemon", .visible), .init("clear_design_temp_files", .rest),
        .init("install_quit_signal", .visible), .init("start_watchdog", .rest), .init("install_debug_timings", .rest),
        .init("install_native_caret", .visible), .init("configure_window_placement", .visible),
        .init("publish_cli_pointer", .rest), .init("start_copy_guide", .rest), .init("read_settings", .visible),
        .init("prime_terminal_theme", .visible), .init("prime_browser_import", .rest), .init("start_theme", .visible),
        .init("start_desktop_backdrop", .rest), .init("register_page_roots", .rest), .init("make_services", .visible),
        .init("install_hang_reporting", .rest), .init("write_launch_times", .rest), .init("bind_actions", .visible),
        .init("start_keybinds", .rest), .init("start_live_config", .rest), .init("install_terminal_hooks", .rest),
        .init("start_settings_and_control", .rest), .init("prewarm_new_tab", .rest), .init("make_main_menu", .visible),
        .init("start_daemon", .visible), .init("start_cloud", .rest), .init("start_post_frame_services", .rest),
        .init("install_window_callbacks", .visible), .init("start_settings_followers", .rest),
        .init("start_control_socket", .rest),
    ]

    public static var invalidStageZeroTasks: [LaunchTask] {
        finishLaunching.filter { $0.stage == .shell && !stageZeroAllowlist.contains($0.name) }
    }

}
