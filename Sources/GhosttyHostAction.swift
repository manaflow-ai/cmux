import GhosttyKit
import os

nonisolated private let ghosttyActionLogger = Logger(
    subsystem: "com.cmuxterm.app", category: "ghostty.actions"
)

/// Host intents decoded after Ghostty has evaluated a binding or key sequence.
enum GhosttyHostAction: Sendable {
    case newWorkspace
    case closeWorkspace
    case selectWorkspace(Int)
    case moveWorkspace(Int)
    case newWindow
    case closeWindow
    case toggleFullScreen
    case commandPalette
    case openConfig
    case quit
    case unsupported(String)

    init?(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB: self = .newWorkspace
        case GHOSTTY_ACTION_CLOSE_TAB:
            switch action.action.close_tab_mode {
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS: self = .closeWorkspace
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: self = .unsupported("close_tab:other")
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: self = .unsupported("close_tab:right")
            default: self = .unsupported("close_tab:unknown_mode")
            }
        case GHOSTTY_ACTION_GOTO_TAB: self = .selectWorkspace(Int(action.action.goto_tab.rawValue))
        case GHOSTTY_ACTION_MOVE_TAB: self = .moveWorkspace(action.action.move_tab.amount)
        case GHOSTTY_ACTION_NEW_WINDOW: self = .newWindow
        case GHOSTTY_ACTION_CLOSE_WINDOW: self = .closeWindow
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            self = action.action.toggle_fullscreen == GHOSTTY_FULLSCREEN_NATIVE
                ? .toggleFullScreen : .unsupported("toggle_fullscreen:non-native")
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE: self = .commandPalette
        case GHOSTTY_ACTION_OPEN_CONFIG: self = .openConfig
        case GHOSTTY_ACTION_QUIT: self = .quit
        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS: self = .unsupported("close_all_windows")
        case GHOSTTY_ACTION_GOTO_WINDOW: self = .unsupported("goto_window")
        case GHOSTTY_ACTION_TOGGLE_MAXIMIZE: self = .unsupported("toggle_maximize")
        case GHOSTTY_ACTION_TOGGLE_VISIBILITY: self = .unsupported("toggle_visibility")
        case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL: self = .unsupported("toggle_quick_terminal")
        case GHOSTTY_ACTION_RESET_WINDOW_SIZE: self = .unsupported("reset_window_size")
        case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW: self = .unsupported("toggle_tab_overview")
        case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS: self = .unsupported("toggle_window_decorations")
        case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY: self = .unsupported("toggle_background_opacity")
        case GHOSTTY_ACTION_PROMPT_TITLE:
            self = .unsupported(action.action.prompt_title == GHOSTTY_PROMPT_TITLE_TAB
                ? "prompt_tab_title" : "prompt_surface_title")
        case GHOSTTY_ACTION_SET_TAB_TITLE: self = .unsupported("set_tab_title")
        case GHOSTTY_ACTION_INSPECTOR: self = .unsupported("inspector")
        case GHOSTTY_ACTION_SHOW_GTK_INSPECTOR: self = .unsupported("show_gtk_inspector")
        case GHOSTTY_ACTION_CHECK_FOR_UPDATES: self = .unsupported("check_for_updates")
        case GHOSTTY_ACTION_UNDO: self = .unsupported("undo")
        case GHOSTTY_ACTION_REDO: self = .unsupported("redo")
        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD: self = .unsupported("copy_title_to_clipboard")
        case GHOSTTY_ACTION_PRESENT_TERMINAL: self = .unsupported("present_terminal")
        case GHOSTTY_ACTION_FLOAT_WINDOW: self = .unsupported("toggle_window_float_on_top")
        case GHOSTTY_ACTION_SECURE_INPUT: self = .unsupported("toggle_secure_input")
        case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD: self = .unsupported("show_on_screen_keyboard")
        default: return nil
        }
    }

    func reportUnavailable() {
        ghosttyActionLogger.warning("Ghostty host action unavailable for its target: \(String(describing: self), privacy: .public)")
    }

    func reportUnsupported(_ name: String) {
        ghosttyActionLogger.warning("Unsupported Ghostty action: \(name, privacy: .public). See docs/ghostty-keybindings.md.")
    }

    static func reportUnhandled(_ tag: ghostty_action_tag_e) {
        // These are runtime notifications, not unimplemented user commands.
        switch tag {
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_RENDER_INSPECTOR, GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_QUIT_TIMER,
             GHOSTTY_ACTION_PROGRESS_REPORT,
             GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_READONLY:
            return
        default:
            ghosttyActionLogger.warning("Unhandled Ghostty action tag: \(tag.rawValue, privacy: .public)")
        }
    }
}
