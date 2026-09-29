import AppKit
import GhosttyKit

/// Window, tab, and split requests from Ghostty keybinds (`new_tab`,
/// `goto_split:left`, ...). Layout lives in cmux-tui, so the App maps these to
/// daemon commands; the terminal module never acts on them.
public nonisolated enum TerminalHostAction: Sendable, Equatable {
    public enum SplitDirection: Sendable, Equatable { case right, down, left, up }
    public enum SplitNavigation: Sendable, Equatable { case previous, next, up, down, left, right }
    public enum TabTarget: Sendable, Equatable { case previous, next, last, index(Int) }
    public enum CloseTabMode: Sendable, Equatable { case this, others, right }

    case newWindow
    case newTab
    case closeTab(CloseTabMode)
    case closeWindow
    case closeAllWindows
    case quit
    case newSplit(SplitDirection)
    case gotoSplit(SplitNavigation)
    case resizeSplit(SplitDirection, amount: Int)
    case equalizeSplits
    case toggleSplitZoom
    case gotoTab(TabTarget)
    case moveTab(Int)
    case toggleFullscreen
    case toggleMaximize
    case toggleCommandPalette
    case toggleInspector
    case promptTitle
    case checkForUpdates
    case undo
    case redo
}

/// OSC 9;4 progress (`GHOSTTY_ACTION_PROGRESS_REPORT`).
public nonisolated enum TerminalProgress: Sendable, Equatable {
    /// 0...100 when the program reported a value.
    case normal(Int?)
    case error(Int?)
    case paused(Int?)
    case indeterminate
}

/// Result of a shell command reported through OSC 133 (`COMMAND_FINISHED`).
public nonisolated struct TerminalCommandResult: Sendable, Equatable {
    public var exitCode: Int?
    public var duration: Duration
}

/// Scroll position of the viewport in the scrollback (`SCROLLBAR`).
public nonisolated struct TerminalScrollbar: Sendable, Equatable {
    public var totalRows: UInt64
    public var offsetRows: UInt64
    public var visibleRows: UInt64
}

/// Find-in-terminal state (`START_SEARCH`, `SEARCH_TOTAL`, ...). The host
/// draws the find bar and drives it through ``TerminalSurfaceView/search(_:)``.
public nonisolated struct TerminalSearchState: Sendable, Equatable {
    public var needle: String
    public var total: Int?
    public var selected: Int?
}

/// One action from `action_cb`, copied out of C memory so it can cross an
/// actor hop.
nonisolated enum GhosttyAction: Sendable {
    case host(TerminalHostAction)
    case setTitle(String)
    case pwd(String)
    case ringBell
    case desktopNotification(title: String, body: String)
    case openURL(String)
    case mouseShape(ghostty_action_mouse_shape_e)
    case mouseVisible(Bool)
    case mouseOverLink(String?)
    case cellSize(width: UInt32, height: UInt32)
    case rendererHealthy(Bool)
    case progress(TerminalProgress?)
    case commandFinished(TerminalCommandResult)
    case childExited(exitCode: UInt32)
    case secureInput(ghostty_action_secure_input_e)
    case readOnly(Bool)
    case keySequence(active: Bool)
    case backgroundColor(red: UInt8, green: UInt8, blue: UInt8)
    /// A clone the receiver must adopt or free.
    case configChange(UncheckedPointer)
    case reloadConfig(soft: Bool)
    case openConfig
    case scrollbar(TerminalScrollbar)
    case startSearch(String)
    case endSearch
    case searchTotal(Int?)
    case searchSelected(Int?)
    case copyTitleToClipboard
    case render
}

nonisolated enum GhosttyActionDecoder {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func decode(_ action: ghostty_action_s) -> GhosttyAction? {
        let payload = action.action
        switch action.tag {
        case GHOSTTY_ACTION_QUIT: return .host(.quit)
        case GHOSTTY_ACTION_NEW_WINDOW: return .host(.newWindow)
        case GHOSTTY_ACTION_NEW_TAB: return .host(.newTab)
        case GHOSTTY_ACTION_CLOSE_TAB:
            let mode: TerminalHostAction.CloseTabMode = switch payload.close_tab_mode {
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: .others
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: .right
            default: .this
            }
            return .host(.closeTab(mode))
        case GHOSTTY_ACTION_CLOSE_WINDOW: return .host(.closeWindow)
        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS: return .host(.closeAllWindows)
        case GHOSTTY_ACTION_NEW_SPLIT: return .host(.newSplit(splitDirection(payload.new_split)))
        case GHOSTTY_ACTION_GOTO_SPLIT:
            let target: TerminalHostAction.SplitNavigation = switch payload.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: .previous
            case GHOSTTY_GOTO_SPLIT_NEXT: .next
            case GHOSTTY_GOTO_SPLIT_UP: .up
            case GHOSTTY_GOTO_SPLIT_DOWN: .down
            case GHOSTTY_GOTO_SPLIT_LEFT: .left
            default: .right
            }
            return .host(.gotoSplit(target))
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = payload.resize_split
            let direction: TerminalHostAction.SplitDirection = switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: .left
            default: .right
            }
            return .host(.resizeSplit(direction, amount: Int(resize.amount)))
        case GHOSTTY_ACTION_EQUALIZE_SPLITS: return .host(.equalizeSplits)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: return .host(.toggleSplitZoom)
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = payload.goto_tab.rawValue
            let target: TerminalHostAction.TabTarget = switch raw {
            case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: .previous
            case GHOSTTY_GOTO_TAB_NEXT.rawValue: .next
            case GHOSTTY_GOTO_TAB_LAST.rawValue: .last
            default: .index(Int(raw))
            }
            return .host(.gotoTab(target))
        case GHOSTTY_ACTION_MOVE_TAB: return .host(.moveTab(Int(payload.move_tab.amount)))
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN: return .host(.toggleFullscreen)
        case GHOSTTY_ACTION_TOGGLE_MAXIMIZE: return .host(.toggleMaximize)
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE: return .host(.toggleCommandPalette)
        case GHOSTTY_ACTION_INSPECTOR: return .host(.toggleInspector)
        case GHOSTTY_ACTION_PROMPT_TITLE: return .host(.promptTitle)
        case GHOSTTY_ACTION_CHECK_FOR_UPDATES: return .host(.checkForUpdates)
        case GHOSTTY_ACTION_UNDO: return .host(.undo)
        case GHOSTTY_ACTION_REDO: return .host(.redo)

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = action.tag == GHOSTTY_ACTION_SET_TITLE ? payload.set_title.title : payload.set_tab_title.title
            return .setTitle(title.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_PWD:
            return .pwd(payload.pwd.pwd.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_RING_BELL: return .ringBell
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = payload.desktop_notification
            return .desktopNotification(
                title: note.title.map { String(cString: $0) } ?? "",
                body: note.body.map { String(cString: $0) } ?? ""
            )
        case GHOSTTY_ACTION_OPEN_URL:
            let open = payload.open_url
            guard let url = string(open.url, length: Int(open.len)) else { return nil }
            return .openURL(url)
        case GHOSTTY_ACTION_MOUSE_SHAPE: return .mouseShape(payload.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY: return .mouseVisible(payload.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = payload.mouse_over_link
            return .mouseOverLink(link.len > 0 ? string(link.url, length: Int(link.len)) : nil)
        case GHOSTTY_ACTION_CELL_SIZE:
            return .cellSize(width: payload.cell_size.width, height: payload.cell_size.height)
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return .rendererHealthy(payload.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = payload.progress_report
            let value: Int? = report.progress < 0 ? nil : Int(report.progress)
            let progress: TerminalProgress? = switch report.state {
            case GHOSTTY_PROGRESS_STATE_SET: .normal(value)
            case GHOSTTY_PROGRESS_STATE_ERROR: .error(value)
            case GHOSTTY_PROGRESS_STATE_PAUSE: .paused(value)
            case GHOSTTY_PROGRESS_STATE_INDETERMINATE: .indeterminate
            default: nil
            }
            return .progress(progress)
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = payload.command_finished
            return .commandFinished(TerminalCommandResult(
                exitCode: finished.exit_code < 0 ? nil : Int(finished.exit_code),
                duration: .nanoseconds(Int64(clamping: finished.duration))
            ))
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return .childExited(exitCode: payload.child_exited.exit_code)
        case GHOSTTY_ACTION_SECURE_INPUT: return .secureInput(payload.secure_input)
        case GHOSTTY_ACTION_READONLY: return .readOnly(payload.readonly == GHOSTTY_READONLY_ON)
        case GHOSTTY_ACTION_KEY_SEQUENCE: return .keySequence(active: payload.key_sequence.active)
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = payload.color_change
            guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return nil }
            return .backgroundColor(red: change.r, green: change.g, blue: change.b)
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            guard let config = payload.config_change.config else { return nil }
            return .configChange(UncheckedPointer(raw: ghostty_config_clone(config)))
        case GHOSTTY_ACTION_RELOAD_CONFIG: return .reloadConfig(soft: payload.reload_config.soft)
        case GHOSTTY_ACTION_OPEN_CONFIG: return .openConfig
        case GHOSTTY_ACTION_SCROLLBAR:
            let bar = payload.scrollbar
            return .scrollbar(TerminalScrollbar(totalRows: bar.total, offsetRows: bar.offset, visibleRows: bar.len))
        case GHOSTTY_ACTION_START_SEARCH:
            return .startSearch(payload.start_search.needle.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_END_SEARCH: return .endSearch
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = payload.search_total.total
            return .searchTotal(total < 0 ? nil : Int(total))
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = payload.search_selected.selected
            return .searchSelected(selected < 0 ? nil : Int(selected))
        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD: return .copyTitleToClipboard
        case GHOSTTY_ACTION_RENDER: return .render
        default:
            return nil
        }
    }

    private static func splitDirection(_ value: ghostty_action_split_direction_e) -> TerminalHostAction.SplitDirection {
        switch value {
        case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
        case GHOSTTY_SPLIT_DIRECTION_UP: .up
        default: .right
        }
    }

    private static func string(_ pointer: UnsafePointer<CChar>?, length: Int) -> String? {
        guard let pointer, length > 0 else { return nil }
        let buffer = UnsafeRawBufferPointer(start: pointer, count: length)
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Routes decoded actions on the main actor.
enum GhosttyActionDispatcher {
    static func dispatch(_ action: GhosttyAction, bridge: SurfaceBridge?, runtime: GhosttyRuntime?) -> Bool {
        switch action {
        case .configChange(let pointer):
            // Surface-targeted config changes are per-surface overrides the
            // renderer already applied; only the app-level one is adopted.
            guard let config = pointer.raw else { return true }
            if bridge == nil, let runtime {
                runtime.adoptAppliedConfig(config)
            } else {
                ghostty_config_free(config)
            }
            return true
        case .reloadConfig(let soft):
            guard let runtime else { return false }
            if soft, let app = runtime.app, let config = runtime.config {
                ghostty_app_update_config(app, config)
            } else {
                runtime.reloadConfig()
            }
            return true
        case .openConfig:
            let path = ghostty_config_open_path()
            defer { ghostty_string_free(path) }
            guard let pointer = path.ptr, path.len > 0 else { return false }
            let text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(path.len)), as: UTF8.self)
            NSWorkspace.shared.open(URL(fileURLWithPath: text))
            return true
        case .host(let hostAction):
            if let view = bridge?.view {
                return view.handleHostAction(hostAction)
            }
            return runtime?.appActionHandler?(hostAction) ?? false
        default:
            guard let view = bridge?.view else { return false }
            return view.applyAction(action)
        }
    }
}
