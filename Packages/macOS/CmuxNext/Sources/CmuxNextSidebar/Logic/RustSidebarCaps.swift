import CCmuxLayoutReducerFFI

/// Per-project caps and the Needs you section, decided in Rust (cmux-layout-reducer `sidebar_caps`, Leo 2026-11-10:
/// "just make it configurable ... ChatGPT shows like 5 or so per project and then a show more"). The sidebar passes a
/// list's length and only its active rows; Rust answers the rows to draw, in order, and the tail row. Its work is the
/// rows drawn, never the hidden ones (design/sidebar.md "Per-project caps").
nonisolated enum RustSidebarCaps {
    struct Flags: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let pinned = Flags(rawValue: UInt8(CMUX_SIDEBAR_ACTIVE_PINNED))
        static let waiting = Flags(rawValue: UInt8(CMUX_SIDEBAR_ACTIVE_WAITING))
        static let unread = Flags(rawValue: UInt8(CMUX_SIDEBAR_ACTIVE_UNREAD))
        static let running = Flags(rawValue: UInt8(CMUX_SIDEBAR_ACTIVE_RUNNING))
        static let keep = Flags(rawValue: UInt8(CMUX_SIDEBAR_ACTIVE_KEEP))

        /// What a workspace row's state makes it: yellow, blue, running. Pinned and kept are the caller's.
        static func of(_ ws: SidebarWorkspace) -> Flags {
            var flags: Flags = []
            if ws.agentChip == .needsYou { flags.insert(.waiting) }
            if ws.unread.isUnread || ws.agentChip == .done { flags.insert(.unread) }
            if ws.agentWorking { flags.insert(.running) }
            switch ws.activity {
            case .waiting: flags.insert(.waiting)
            case .working, .busy, .paused: flags.insert(.running)
            case .idle, .error, .success: break
            }
            return flags
        }
    }

    /// What decides a list's rows.
    struct Caps: Hashable, Sendable {
        /// Quiet rows before "Show N more"; 0 shows all.
        var cap: Int
        /// Rows "Show N more" revealed past the cap.
        var revealed: Int
        /// Yellow then blue rise to the top of the project.
        var floats: Bool
        /// Running rows count as active for floating and Needs you.
        var includeWorking: Bool
    }

    enum Tail: Hashable, Sendable {
        case none
        /// "Show `next` more"; `hidden` rows are behind it.
        case showMore(hidden: Int, next: Int)
        case showLess
    }

    struct Rows: Hashable, Sendable {
        var rows: [Int]
        var tail: Tail
        /// What one press of the tail row stores as the list's revealed count.
        var revealedAfterPress: Int
    }

    /// The rows of a list of `count` entries whose active entries are `active` (ascending positions); nil when the
    /// call fails (the caller then draws every row, never a wrong subset).
    static func project(count: Int, active: [(position: Int, flags: Flags)], caps: Caps) -> Rows? {
        SidebarPerfCounters.add(.ffiCalls)
        let entries = active.map { CmuxSidebarActive(index: UInt32(clamping: $0.position), flags: $0.flags.rawValue, reserved: (0, 0, 0)) }
        var c = CmuxSidebarCaps(cap: UInt32(clamping: caps.cap), revealed: UInt32(clamping: caps.revealed),
                                floats: caps.floats ? 1 : 0, include_working: caps.includeWorking ? 1 : 0, reserved: (0, 0))
        let quiet = count - entries.count
        var capacity = entries.count + (caps.cap == 0 ? quiet : min(quiet, caps.cap + caps.revealed + 1)) + 1
        for _ in 0..<2 {
            var out = [UInt32](repeating: 0, count: max(capacity, 1))
            var tail = CmuxSidebarProjectTail()
            let code = entries.withUnsafeBufferPointer { e in
                out.withUnsafeMutableBufferPointer { o in
                    cmux_sidebar_project_rows(UInt32(clamping: count), e.baseAddress, e.count, &c, o.baseAddress, o.count, &tail)
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, Int(tail.rows) > capacity {
                capacity = Int(tail.rows)
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK else { return nil }
            let shape: Tail = switch Int(tail.kind) {
            case Int(CMUX_SIDEBAR_TAIL_SHOW_MORE): .showMore(hidden: Int(tail.hidden), next: Int(tail.next))
            case Int(CMUX_SIDEBAR_TAIL_SHOW_LESS): .showLess
            default: .none
            }
            return Rows(rows: out.prefix(Int(tail.rows)).map(Int.init), tail: shape, revealedAfterPress: Int(tail.revealed_after_press))
        }
        return nil
    }

    /// The Needs you section's rows (positions in `rows`' drawn order), at most `limit` (0: three), and how many more.
    static func needsYou(_ rows: [(position: Int, flags: Flags)], includeWorking: Bool, limit: Int = 0) -> (rows: [Int], more: Int)? {
        SidebarPerfCounters.add(.ffiCalls)
        let entries = rows.map { CmuxSidebarActive(index: UInt32(clamping: $0.position), flags: $0.flags.rawValue, reserved: (0, 0, 0)) }
        var out = [UInt32](repeating: 0, count: max(limit == 0 ? 3 : limit, 1))
        var length = 0
        var more: UInt32 = 0
        let code = entries.withUnsafeBufferPointer { e in
            out.withUnsafeMutableBufferPointer { o in
                cmux_sidebar_needs_you(e.baseAddress, e.count, includeWorking ? 1 : 0, UInt32(clamping: limit), o.baseAddress, o.count,
                                       &length, &more)
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK else { return nil }
        return (out.prefix(length).map(Int.init), Int(more))
    }
}
