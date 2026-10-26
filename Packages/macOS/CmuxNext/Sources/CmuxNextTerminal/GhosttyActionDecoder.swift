import GhosttyNextKit

/// Copies `ghostty_action_s` (ghostty.h:1143-1250) into a Sendable value.
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
        case GHOSTTY_ACTION_PROMPT_TITLE:
            return .host(payload.prompt_title == GHOSTTY_PROMPT_TITLE_WINDOW ? .promptWindowTitle : .promptTitle)
        case GHOSTTY_ACTION_SET_WINDOW_TITLE:
            // Same payload layout as set_title (apprt SetTitle).
            // SAFETY: the payload's title pointer, valid for this callback; cString copies it.
            return .host(.setWindowTitle(unsafe cString(payload.set_title.title) ?? ""))
        case GHOSTTY_ACTION_TOGGLE_VISIBILITY: return .host(.toggleVisibility)
        case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW: return .host(.toggleTabOverview)
        case GHOSTTY_ACTION_PRESENT_TERMINAL: return .host(.presentTerminal)
        case GHOSTTY_ACTION_GOTO_WINDOW: return .host(.gotoWindow(next: payload.goto_window == GHOSTTY_GOTO_WINDOW_NEXT))
        case GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW: return .host(.moveTabToNewWindow)
        case GHOSTTY_ACTION_CHECK_FOR_UPDATES: return .host(.checkForUpdates)
        case GHOSTTY_ACTION_UNDO: return .host(.undo)
        case GHOSTTY_ACTION_REDO: return .host(.redo)

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            // SAFETY: reads the payload's title pointer, valid for this callback (copied below).
            let title = unsafe action.tag == GHOSTTY_ACTION_SET_TITLE ? payload.set_title.title : payload.set_tab_title.title
            // SAFETY: as above; cString copies the title.
            return .setTitle(unsafe cString(title) ?? "")
        case GHOSTTY_ACTION_PWD:
            // SAFETY: the payload's pwd pointer, valid for this callback; cString copies it.
            return .pwd(unsafe cString(payload.pwd.pwd) ?? "")
        case GHOSTTY_ACTION_RING_BELL: return .ringBell
        // GHOSTTY_ACTION_DESKTOP_NOTIFICATION stays unhandled: the daemon
        // parses OSC 9/777/99 from every terminal's output, shown or not,
        // and posts it with source `terminal` (notification-source-v1).
        case GHOSTTY_ACTION_OPEN_URL:
            let open = payload.open_url
            // SAFETY: the payload's url pointer and its length, valid for this callback; string copies them.
            guard let url = string(unsafe open.url, length: Int(open.len)) else { return nil }
            return .openURL(url)
        case GHOSTTY_ACTION_MOUSE_SHAPE: return .mouseShape(payload.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY: return .mouseVisible(payload.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let link = payload.mouse_over_link
            // SAFETY: the payload's url pointer and its length, valid for this callback; string copies them.
            return .mouseOverLink(link.len > 0 ? string(unsafe link.url, length: Int(link.len)) : nil)
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
            // SAFETY: the applied config is valid for this callback; the clone is a new handle
            // the action owns (GhosttyActionDispatcher frees it once).
            guard let config = unsafe payload.config_change.config else { return nil }
            // SAFETY: as above.
            return .configChange(unsafe UncheckedPointer(raw: ghostty_config_clone(config)))
        case GHOSTTY_ACTION_RELOAD_CONFIG: return .reloadConfig(soft: payload.reload_config.soft)
        case GHOSTTY_ACTION_OPEN_CONFIG: return .openConfig
        case GHOSTTY_ACTION_SCROLLBAR:
            let bar = payload.scrollbar
            return .scrollbar(TerminalScrollbar(totalRows: bar.total, offsetRows: bar.offset, visibleRows: bar.len))
        case GHOSTTY_ACTION_START_SEARCH:
            // SAFETY: the payload's needle pointer, valid for this callback; cString copies it.
            return .startSearch(unsafe cString(payload.start_search.needle) ?? "")
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

    // The action's strings are valid only during the action callback (ghostty.h), which is when
    // `decode` runs: both readers copy them into Swift strings before it returns.

    /// `length` bytes at `pointer`, the payload's string and its length.
    @safe
    private static func string(_ pointer: UnsafePointer<CChar>?, length: Int) -> String? {
        // SAFETY: only the address is read here; the bytes are read below, with their length.
        guard let pointer = unsafe pointer, length > 0 else { return nil }
        // SAFETY: Ghostty's payload pairs the pointer with its byte count; both come from the
        // same payload, and the bytes live for the callback (above).
        let buffer = unsafe UnsafeRawBufferPointer(start: pointer, count: length)
        // SAFETY: as above; String(decoding:) copies.
        return unsafe String(decoding: buffer, as: UTF8.self)
    }

    /// The payload's NUL-terminated string, nil for a null pointer.
    @safe
    private static func cString(_ pointer: UnsafePointer<CChar>?) -> String? {
        // SAFETY: Ghostty's titles, pwd and needle are NUL-terminated and live for the
        // callback (above); String(cString:) copies.
        unsafe pointer.map { unsafe String(cString: $0) }
    }
}
