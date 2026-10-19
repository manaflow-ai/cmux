import CCmuxLayoutReducerFFI
import Foundation

/// One window's focus machine: `cmux-focus-core`'s state and rules
/// (cmux-tui/crates/cmux-focus-core; plans/cmux-next/focus.md section 4)
/// behind the app FFI's `cmux_focus_*` handle. The machine owns the state;
/// the app sends one small typed event per focus change (a topology only
/// when it changed) and reads a typed reply: no JSON, no copy of the whole
/// state, no buffer per call. One in-process call on the caller's thread,
/// no daemon round trip. Not thread-safe: one per window, on the main actor.
public nonisolated final class FocusMachine {
    private let handle: OpaquePointer

    public init() {
        handle = cmux_focus_new()
    }

    deinit {
        cmux_focus_free(handle)
    }

    /// Reduces `event` and refreshes `state` (its topology and focus-mode
    /// set follow the machine's own changes). Nil when the ABI refused it
    /// (a wire mismatch; the state is unchanged).
    public func send(_ event: FocusEvent, into state: inout FocusState) -> (changed: Bool, effects: [FocusEffect])? {
        if case .topology(let topology) = event { return set(topology, into: &state) }
        var wire = FocusWire()
        var encoded = wire.event(event)
        let list = wire.list
        let reply = list.withUnsafeBufferPointer { list in
            encoded.list = list.baseAddress
            return wire.bytes.withUnsafeBufferPointer { bytes in
                withUnsafePointer(to: &encoded) { cmux_focus_send(handle, $0, bytes.baseAddress, bytes.count) }
            }
        }
        guard let result = read(reply, into: &state) else { return nil }
        for effect in result.effects { Self.mirror(effect, into: &state) }
        return result
    }

    private func set(_ topology: FocusTopology, into state: inout FocusState) -> (changed: Bool, effects: [FocusEffect])? {
        var wire = FocusWire()
        var panes: [CmuxFocusPane] = []
        var tabs: [CmuxFocusTab] = []
        var columns: [CmuxFocusColumn] = []
        var columnPanes: [CmuxFocusStr] = []
        panes.reserveCapacity(topology.panes.count)
        for pane in topology.panes {
            let start = UInt32(tabs.count)
            for tab in pane.tabs {
                tabs.append(CmuxFocusTab(id: wire.put(tab.id), surface: wire.put(tab.surface), kind: tab.kind.code, reserved: 0))
            }
            panes.append(CmuxFocusPane(id: wire.put(pane.id), selected: wire.put(pane.selected), tab_start: start,
                                       tab_count: UInt32(tabs.count) - start))
        }
        for (index, screen) in topology.screens.enumerated() {
            for column in screen {
                let start = UInt32(columnPanes.count)
                for pane in column.panes { columnPanes.append(wire.put(pane)) }
                columns.append(CmuxFocusColumn(id: wire.put(column.id), screen: UInt32(index), pane_start: start,
                                               pane_count: UInt32(columnPanes.count) - start, reserved: 0))
            }
        }
        let workspace = wire.put(topology.workspace)
        let screenCount = UInt32(topology.screens.count)
        let reply = panes.withUnsafeBufferPointer { panes in
            tabs.withUnsafeBufferPointer { tabs in
                columns.withUnsafeBufferPointer { columns in
                    columnPanes.withUnsafeBufferPointer { columnPanes in
                        wire.bytes.withUnsafeBufferPointer { bytes in
                            var encoded = CmuxFocusTopology(
                                workspace: workspace, panes: panes.baseAddress, tabs: tabs.baseAddress, columns: columns.baseAddress,
                                column_panes: columnPanes.baseAddress, pane_count: UInt32(panes.count), tab_count: UInt32(tabs.count),
                                column_count: UInt32(columns.count), column_pane_count: UInt32(columnPanes.count),
                                screen_count: screenCount, reserved: 0)
                            return cmux_focus_set_topology(handle, &encoded, bytes.baseAddress, bytes.count)
                        }
                    }
                }
            }
        }
        guard let result = read(reply, into: &state) else { return nil }
        // The machine holds this topology now (a refused one keeps the old).
        state.topology = topology
        for effect in result.effects { Self.mirror(effect, into: &state) }
        return result
    }

    /// `layout.closeFocus`, the successor rule when the focused pane closes:
    /// the most recently focused pane, else the previous neighbor.
    public func setCloseFocus(mostRecent: Bool) {
        cmux_focus_set_close_focus(handle, mostRecent ? 1 : 0)
    }

    /// The focus history of `workspace` (nil: the shown one), newest first.
    public func recentPanes(in workspace: String? = nil) -> [String] {
        let list: UnsafePointer<CmuxFocusStrings>? = if let workspace {
            Array(workspace.utf8).withUnsafeBufferPointer { cmux_focus_recent_panes(handle, $0.baseAddress, $0.count, 1) }
        } else {
            cmux_focus_recent_panes(handle, nil, 0, 0)
        }
        guard let list = list?.pointee, list.count > 0, let items = list.items, let bytes = list.bytes else { return [] }
        return (0..<Int(list.count)).map { Self.string(items[$0], bytes, Int(list.bytes_len)) ?? "" }
    }

    /// The last focused pane of each workspace (a window record save).
    public func remembered() -> [String: String] {
        guard let list = cmux_focus_remembered(handle)?.pointee, list.count > 1, let items = list.items,
              let bytes = list.bytes else { return [:] }
        var out: [String: String] = [:]
        for index in stride(from: 0, to: Int(list.count) - 1, by: 2) {
            if let workspace = Self.string(items[index], bytes, Int(list.bytes_len)),
               let pane = Self.string(items[index + 1], bytes, Int(list.bytes_len)) { out[workspace] = pane }
        }
        return out
    }

    /// The whole state as JSON: journal checkpoints only, never per event.
    public func checkpoint() -> FocusCheckpoint {
        guard let text = cmux_focus_export_json(handle) else { return FocusCheckpoint(json: "{}") }
        defer { cmux_focus_string_free(text) }
        return FocusCheckpoint(json: String(cString: text))
    }

    /// Replaces the state with a checkpoint (journal replay) and returns its
    /// view. Nil when it does not decode.
    public func restore(_ checkpoint: FocusCheckpoint) -> FocusState? {
        let code = Array(checkpoint.json.utf8).withUnsafeBufferPointer { cmux_focus_import_json(handle, $0.baseAddress, $0.count) }
        guard code == CMUX_LAYOUT_REDUCER_OK else { return nil }
        var state = FocusState()
        let saved = checkpoint.saved
        state.topology = saved?.topology ?? FocusTopology()
        state.browserFocusMode = Set(saved?.browserFocusMode ?? [])
        guard read(cmux_focus_current(handle), into: &state) != nil else { return nil }
        return state
    }

    /// `FocusEvent.changesView`, the machine's own rule.
    public static func changesView(_ event: FocusEvent) -> Bool {
        var wire = FocusWire()
        var encoded = wire.event(event)
        let list = wire.list
        return list.withUnsafeBufferPointer { list in
            encoded.list = list.baseAddress
            return wire.bytes.withUnsafeBufferPointer { bytes in
                withUnsafePointer(to: &encoded) { cmux_focus_changes_view($0, bytes.baseAddress, bytes.count) } != 0
            }
        }
    }

    // MARK: Reply

    private func read(_ reply: UnsafePointer<CmuxFocusReply>?, into state: inout FocusState) -> (changed: Bool, effects: [FocusEffect])? {
        guard let reply = reply?.pointee else { return nil }
        let bytes = reply.strings
        let length = Int(reply.strings_len)
        func string(_ range: CmuxFocusStr) -> String? { bytes.flatMap { Self.string(range, $0, length) } }
        // ok 0: refused (the fields are the previous, valid ones) or failed
        // part way (the fields are the state as it is now). Either way the
        // view takes the fields, and the event counts as refused.
        if reply.changed != 0 || reply.ok == 0 {
            state.windowKey = reply.window_key != 0
            state.appActive = reply.app_active != 0
            state.sidebarHidden = reply.sidebar_hidden != 0
            state.pane = string(reply.pane)
            state.target = .init(code: reply.target, keyboard: reply.target_keyboard)
            if let overlays = reply.overlays {
                state.overlays = (0..<Int(reply.overlay_count)).compactMap { FocusState.Overlay(code: overlays[$0]) }
            } else {
                state.overlays = []
            }
            state.generation = reply.generation
            state.isDragging = reply.dragging != 0
            state.expectation = reply.has_expectation == 0 ? nil : string(reply.expectation_id).map { id in
                FocusState.Expectation(key: reply.expectation_key == 1 ? .tab(id) : .surface(id),
                                       target: .init(code: reply.expectation_target, keyboard: reply.expectation_target_keyboard),
                                       awayFrom: string(reply.expectation_away_from), generation: reply.expectation_generation)
            }
            state.resolved = Self.resolved(reply.resolved, string)
            state.underlying = Self.resolved(reply.underlying, string)
            state.context = .init(bits: reply.context)
            state.isBrowserFocusModeActive = reply.browser_focus_mode_active != 0
        }
        guard reply.ok != 0 else { return nil }
        var effects: [FocusEffect] = []
        if reply.effect_count > 0, let list = reply.effects {
            effects.reserveCapacity(Int(reply.effect_count))
            for index in 0..<Int(reply.effect_count) {
                let effect = list[index]
                switch effect.kind {
                case 0: effects.append(.select(pane: string(effect.pane) ?? "", tab: string(effect.tab) ?? ""))
                case 1: effects.append(.revealPane(string(effect.pane) ?? ""))
                case 2: effects.append(.moveResponder(Self.resolved(effect.resolved, string)))
                case 3: effects.append(.publishContext(.init(bits: effect.context)))
                default: effects.append(.browserFocusMode(tab: string(effect.tab) ?? "", active: effect.active != 0))
                }
            }
        }
        return (reply.changed != 0, effects)
    }

    /// Keeps the view's topology and focus-mode set equal to the machine's.
    private static func mirror(_ effect: FocusEffect, into state: inout FocusState) {
        switch effect {
        case .select(let pane, let tab):
            if let index = state.topology.panes.firstIndex(where: { $0.id == pane }) { state.topology.panes[index].selected = tab }
        case .browserFocusMode(let tab, let active):
            if active { state.browserFocusMode.insert(tab) } else { state.browserFocusMode.remove(tab) }
        default:
            break
        }
    }

    private static func string(_ range: CmuxFocusStr, _ bytes: UnsafePointer<UInt8>, _ length: Int) -> String? {
        guard range.offset != UInt32.max, Int(range.offset) + Int(range.len) <= length else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes + Int(range.offset), count: Int(range.len)), as: UTF8.self)
    }

    private static func resolved(_ value: CmuxFocusResolved, _ string: (CmuxFocusStr) -> String?) -> FocusState.Resolved {
        let pane = string(value.pane) ?? ""
        let tab = string(value.tab) ?? ""
        switch value.kind {
        case 0: return .terminal(pane: pane, tab: tab)
        case 1: return .browserPage(pane: pane, tab: tab)
        case 2: return .addressBar(pane: pane, tab: tab)
        case 3: return .findBar(pane: pane, tab: tab)
        case 4: return .devTools(pane: pane, tab: tab)
        case 5: return .agentPage(pane: pane, tab: tab)
        case 6: return .page(pane: pane, tab: tab)
        case 7: return .conversation(pane: pane, tab: tab)
        case 8: return .emptyPane(pane: pane)
        case 9: return .sidebar
        case 10: return .sidebarField
        case 11: return .textField
        case 12: return FocusState.Overlay(code: value.overlay).map { .overlay($0) } ?? .none
        default: return .none
        }
    }
}

/// A focus machine's whole state as JSON (`cmux_focus_export_json`): the
/// input journal's checkpoint, so replay can start mid-ring.
public nonisolated struct FocusCheckpoint: Hashable, Sendable, Codable {
    public var json: String

    public init(json: String) { self.json = json }

    /// The parts of the checkpoint the app's view keeps itself.
    struct Saved: Decodable {
        var topology: FocusTopology?
        var browserFocusMode: [String]?
    }

    var saved: Saved? { try? JSONDecoder().decode(Saved.self, from: Data(json.utf8)) }

    /// Same state (the JSON's key order is not part of it).
    public func matches(_ other: FocusCheckpoint) -> Bool {
        let parse = { (text: String) in try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary }
        guard let mine = parse(json), let theirs = parse(other.json) else { return false }
        return mine.isEqual(theirs)
    }
}

/// The string table of one request.
private nonisolated struct FocusWire {
    var bytes: [UInt8] = []
    var list: [CmuxFocusStr] = []

    mutating func put(_ text: String?) -> CmuxFocusStr {
        guard let text else { return CmuxFocusStr(offset: UInt32.max, len: 0) }
        let offset = UInt32(bytes.count)
        bytes.append(contentsOf: text.utf8)
        return CmuxFocusStr(offset: offset, len: UInt32(bytes.count) - offset)
    }

    /// `event` in `CmuxFocusEvent` form (the header's codes). Not for a
    /// topology (`cmux_focus_set_topology`).
    mutating func event(_ event: FocusEvent) -> CmuxFocusEvent {
        var out = CmuxFocusEvent()
        let absent = CmuxFocusStr(offset: UInt32.max, len: 0)
        (out.a, out.b, out.c) = (absent, absent, absent)
        switch event {
        case .topology:
            out.kind = 255
        case .focusPane(let pane, let workspace, let source):
            out.kind = 0; out.a = put(pane); out.c = put(workspace); out.source = source.code
        case .selectTab(let pane, let tab, let workspace, let source):
            out.kind = 1; out.a = put(pane); out.b = put(tab); out.c = put(workspace); out.source = source.code
        case .focusTarget(let target, let source):
            out.kind = 2; (out.target, out.target_keyboard) = target.code; out.source = source.code
        case .responder(let responder, let source):
            out.kind = 3; out.source = source.code
            switch responder {
            case .content(let pane): out.value = 0; out.a = put(pane)
            case .addressBar(let pane): out.value = 1; out.a = put(pane)
            case .findBar(let pane): out.value = 2; out.a = put(pane)
            case .devTools(let pane): out.value = 3; out.a = put(pane)
            case .sidebar: out.value = 4
            case .sidebarField: out.value = 5
            case .textField: out.value = 6
            case .windowOrNone: out.value = 7
            }
        case .windowKey(let key):
            out.kind = 4; out.value = key ? 1 : 0
        case .appActive(let active):
            out.kind = 5; out.value = active ? 1 : 0
        case .overlayOpened(let overlay):
            out.kind = 6; out.value = overlay.code
        case .overlayClosed(let overlay):
            out.kind = 7; out.value = overlay.code
        case .beginIntent:
            out.kind = 8
        case .expect(let key, let target, let awayFrom, let generation):
            out.kind = 9; (out.target, out.target_keyboard) = target.code; out.b = put(awayFrom); out.generation = generation
            switch key {
            case .surface(let id): out.value = 0; out.a = put(id)
            case .tab(let id): out.value = 1; out.a = put(id)
            }
        case .dragBegan(let tabs, let pane):
            out.kind = 10; out.a = put(pane); setList(tabs, &out)
        case .dragEnded(let outcome):
            out.kind = 11
            switch outcome {
            case .cancelled: out.value = 0
            case .dropped(let tabs, let awayFrom): out.value = 1; out.b = put(awayFrom); setList(tabs, &out)
            case .movedAway: out.value = 2
            }
        case .contentPresented(let pane):
            out.kind = 12; out.a = put(pane)
        case .toggleBrowserFocusMode(let tab):
            out.kind = 13; out.a = put(tab)
        case .sidebarVisibility(let hidden):
            out.kind = 14; out.value = hidden ? 1 : 0
        case .restoredPane(let pane, let workspace):
            out.kind = 15; out.a = put(pane); out.c = put(workspace)
        }
        return out
    }

    private mutating func setList(_ tabs: [String], _ out: inout CmuxFocusEvent) {
        var ranges: [CmuxFocusStr] = []
        for tab in tabs { ranges.append(put(tab)) }
        list = ranges
        out.list_count = UInt32(ranges.count)
    }
}

// MARK: Codes (cmux_layout_reducer_ffi.h, CMUX_FOCUS_*)

private extension FocusEvent.Source {
    nonisolated var code: UInt8 {
        switch self {
        case .mouse: 0
        case .keyboard: 1
        case .cli: 2
        case .palette: 3
        case .programmatic: 4
        }
    }
}

private extension FocusState.Target {
    nonisolated var code: (UInt8, UInt8) {
        switch self {
        case .content: (0, 0)
        case .addressBar: (1, 0)
        case .findBar: (2, 0)
        case .devTools: (3, 0)
        case .sidebar(let keyboard): (4, keyboard ? 1 : 0)
        case .sidebarField: (5, 0)
        case .textField: (6, 0)
        case .none: (7, 0)
        }
    }

    nonisolated init(code: UInt8, keyboard: UInt8) {
        self = switch code {
        case 0: .content
        case 1: .addressBar
        case 2: .findBar
        case 3: .devTools
        case 4: .sidebar(keyboard: keyboard != 0)
        case 5: .sidebarField
        case 6: .textField
        default: .none
        }
    }
}

private extension FocusState.Overlay {
    nonisolated var code: UInt8 {
        switch self {
        case .palette: 0
        case .sheet: 1
        case .rename: 2
        case .groupEditor: 3
        }
    }

    nonisolated init?(code: UInt8) {
        switch code {
        case 0: self = .palette
        case 1: self = .sheet
        case 2: self = .rename
        case 3: self = .groupEditor
        default: return nil
        }
    }
}

private extension FocusState.Context {
    nonisolated init(bits: UInt8) {
        self.init(terminal: bits & 1 != 0, browser: bits & 2 != 0, agent: bits & 4 != 0)
    }
}

private extension FocusTopology.Kind {
    nonisolated var code: UInt32 {
        switch self {
        case .terminal: 0
        case .browser: 1
        case .agent: 2
        case .page: 3
        case .conversation: 4
        case .other: 5
        }
    }
}
