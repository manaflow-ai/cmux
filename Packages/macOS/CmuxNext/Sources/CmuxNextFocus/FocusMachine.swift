import CCmuxLayoutReducerFFI
import Foundation

/// One window's focus machine: `cmux-focus-core`'s state and rules
/// (cmux-tui/crates/cmux-focus-core; plans/cmux-next/focus.md section 4)
/// behind the app FFI's `cmux_focus_*` handle. The machine owns the state;
/// the app sends one small typed event per focus change (a topology only
/// when it changed) and reads a typed reply: no JSON, no copy of the whole
/// state, no buffer per call. One in-process call on the caller's thread,
/// no daemon round trip. Not thread-safe: one per window, on the main actor.
///
/// Memory safety: `handle` is the machine `init` created and `deinit` frees
/// once, so it is live in every method, and one owner calls at a time, as the
/// C ABI requires. A reply or string list the machine returns stays valid
/// only until the next call on the handle (cmux_layout_reducer_ffi.h), so each
/// method reads it before it makes another call.
@safe
public nonisolated final class FocusMachine {
    private let handle: OpaquePointer

    public init() {
        // SAFETY: the machine returns a new handle; this instance owns it.
        unsafe handle = cmux_focus_new()
    }

    deinit {
        // SAFETY: frees the handle init created, exactly once; nothing uses it after.
        unsafe cmux_focus_free(handle)
    }

    /// Reduces `event` and refreshes `state` (its topology and focus-mode
    /// set follow the machine's own changes). Nil when the ABI refused it
    /// (a wire mismatch; the state is unchanged).
    public func send(_ event: FocusEvent, into state: inout FocusState) -> (changed: Bool, effects: [FocusEffect])? {
        if case .topology(let topology) = event { return set(topology, into: &state) }
        var wire = FocusWire()
        let wireEvent = wire.event(event)
        let list = wire.list
        let bytes = wire.bytes
        // SAFETY: `list` and `bytes` view the request's arrays, valid for their closures; the event's list pointer and
        // the string pointer are used only by this call, which reads list_count ranges and bytes.count bytes. The
        // reply is read before the next call on the handle (see the type).
        let result = unsafe list.withUnsafeBufferPointer { list in
            unsafe bytes.withUnsafeBufferPointer { bytes in
                var encoded = unsafe wireEvent.encoded(list: list.baseAddress)
                return unsafe read(cmux_focus_send(handle, &encoded, bytes.baseAddress, bytes.count), into: &state)
            }
        }
        guard let result else { return nil }
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
        let bytes = wire.bytes
        // SAFETY: each buffer views its array, valid for its closure, and the topology carries each base address with
        // that buffer's own count; the call reads them and the strings only while it runs. The reply is read before
        // the next call on the handle (see the type).
        let result = unsafe panes.withUnsafeBufferPointer { panes in
            unsafe tabs.withUnsafeBufferPointer { tabs in
                unsafe columns.withUnsafeBufferPointer { columns in
                    unsafe columnPanes.withUnsafeBufferPointer { columnPanes in
                        unsafe bytes.withUnsafeBufferPointer { bytes in
                            var encoded = unsafe CmuxFocusTopology(
                                workspace: workspace, panes: panes.baseAddress, tabs: tabs.baseAddress, columns: columns.baseAddress,
                                column_panes: columnPanes.baseAddress, pane_count: UInt32(panes.count), tab_count: UInt32(tabs.count),
                                column_count: UInt32(columns.count), column_pane_count: UInt32(columnPanes.count),
                                screen_count: screenCount, reserved: 0)
                            return unsafe read(cmux_focus_set_topology(handle, &encoded, bytes.baseAddress, bytes.count), into: &state)
                        }
                    }
                }
            }
        }
        guard let result else { return nil }
        // The machine holds this topology now (a refused one keeps the old).
        state.topology = topology
        for effect in result.effects { Self.mirror(effect, into: &state) }
        return result
    }

    /// `layout.closeFocus`, the successor rule when the focused pane closes:
    /// the most recently focused pane, else the previous neighbor.
    public func setCloseFocus(mostRecent: Bool) {
        // SAFETY: handle is live (see the type).
        unsafe cmux_focus_set_close_focus(handle, mostRecent ? 1 : 0)
    }

    /// The focus history of `workspace` (nil: the shown one), newest first.
    public func recentPanes(in workspace: String? = nil) -> [String] {
        let name = workspace.map { Array($0.utf8) } ?? []
        // SAFETY: handle is live (see the type); the call reads name.count bytes of the array's buffer, valid for the
        // closure, and its list is read before the next call on the handle.
        let panes = unsafe name.withUnsafeBufferPointer { name in
            unsafe Self.strings(cmux_focus_recent_panes(handle, name.baseAddress, name.count, workspace == nil ? 0 : 1))
        }
        return panes.map { $0 ?? "" }
    }

    /// The last focused pane of each workspace (a window record save).
    public func remembered() -> [String: String] {
        // SAFETY: handle is live (see the type); its list is read before the next call on the handle.
        let items = unsafe Self.strings(cmux_focus_remembered(handle))
        var out: [String: String] = [:]
        for index in stride(from: 0, to: items.count - 1, by: 2) {
            if let workspace = items[index], let pane = items[index + 1] { out[workspace] = pane }
        }
        return out
    }

    /// The whole state as JSON: journal checkpoints only, never per event.
    public func checkpoint() -> FocusCheckpoint {
        // SAFETY: handle is live (see the type); the machine returns a NUL-terminated string the caller owns, or nil.
        guard let text = unsafe cmux_focus_export_json(handle) else { return FocusCheckpoint(json: "{}") }
        // SAFETY: frees that string once, after the copy below.
        defer { unsafe cmux_focus_string_free(text) }
        // SAFETY: `text` is the live NUL-terminated string the machine returned.
        return FocusCheckpoint(json: unsafe String(cString: text))
    }

    /// Replaces the state with a checkpoint (journal replay) and returns its
    /// view. Nil when it does not decode.
    public func restore(_ checkpoint: FocusCheckpoint) -> FocusState? {
        let json = Array(checkpoint.json.utf8)
        // SAFETY: handle is live (see the type); the call reads json.count bytes of the array's buffer, valid for the
        // closure.
        let code = unsafe json.withUnsafeBufferPointer { unsafe cmux_focus_import_json(handle, $0.baseAddress, $0.count) }
        guard code == CMUX_LAYOUT_REDUCER_OK else { return nil }
        var state = FocusState()
        let saved = checkpoint.saved
        state.topology = saved?.topology ?? FocusTopology()
        state.browserFocusMode = Set(saved?.browserFocusMode ?? [])
        // SAFETY: handle is live (see the type); the reply is read before the next call on the handle.
        guard unsafe read(cmux_focus_current(handle), into: &state) != nil else { return nil }
        return state
    }

    /// `FocusEvent.changesView`, the machine's own rule.
    public static func changesView(_ event: FocusEvent) -> Bool {
        var wire = FocusWire()
        let wireEvent = wire.event(event)
        let list = wire.list
        let bytes = wire.bytes
        // SAFETY: `list` and `bytes` view the request's arrays, valid for their closures; the call reads list_count
        // ranges and bytes.count bytes while it runs and keeps no pointer.
        return unsafe list.withUnsafeBufferPointer { list in
            unsafe bytes.withUnsafeBufferPointer { bytes in
                var encoded = unsafe wireEvent.encoded(list: list.baseAddress)
                return unsafe cmux_focus_changes_view(&encoded, bytes.baseAddress, bytes.count) != 0
            }
        }
    }

    // MARK: Reply

    /// Takes a reply into `state`. The caller vouches that `reply` is nil or
    /// the reply of the call it just made on the handle (see the type).
    @unsafe
    private func read(_ reply: UnsafePointer<CmuxFocusReply>?, into state: inout FocusState) -> (changed: Bool, effects: [FocusEffect])? {
        // SAFETY: the caller's contract: `reply` is nil or the live reply. Its buffers hold strings_len bytes,
        // overlay_count codes and effect_count effects (cmux_layout_reducer_ffi.h); they are copied out here, and
        // the rest of this function reads only scalar fields of the local copy `reply`.
        guard let reply = unsafe reply?.pointee else { return nil }
        let bytes = unsafe Self.copy(reply.strings, count: reply.strings_len)
        let overlays = unsafe Self.copy(reply.overlays, count: reply.overlay_count)
        let replyEffects = unsafe Self.copy(reply.effects, count: reply.effect_count)
        func string(_ range: CmuxFocusStr) -> String? { Self.string(range, in: bytes) }
        let changed = unsafe reply.changed != 0, ok = unsafe reply.ok != 0
        // ok 0: refused (the fields are the previous, valid ones) or failed
        // part way (the fields are the state as it is now). Either way the
        // view takes the fields, and the event counts as refused.
        if changed || !ok {
            state.windowKey = unsafe reply.window_key != 0
            state.appActive = unsafe reply.app_active != 0
            state.sidebarHidden = unsafe reply.sidebar_hidden != 0
            state.pane = string(unsafe reply.pane)
            state.target = unsafe .init(code: reply.target, keyboard: reply.target_keyboard)
            state.overlays = overlays.compactMap { FocusState.Overlay(code: $0) }
            state.generation = unsafe reply.generation
            state.isDragging = unsafe reply.dragging != 0
            let key = unsafe reply.expectation_key, awayFrom = unsafe string(reply.expectation_away_from)
            let target = unsafe FocusState.Target(code: reply.expectation_target, keyboard: reply.expectation_target_keyboard)
            let generation = unsafe reply.expectation_generation
            state.expectation = unsafe reply.has_expectation == 0 ? nil : string(reply.expectation_id).map { id in
                FocusState.Expectation(key: key == 1 ? .tab(id) : .surface(id), target: target, awayFrom: awayFrom,
                                       generation: generation)
            }
            state.resolved = Self.resolved(unsafe reply.resolved, string)
            state.underlying = Self.resolved(unsafe reply.underlying, string)
            state.context = unsafe .init(bits: reply.context)
            state.isBrowserFocusModeActive = unsafe reply.browser_focus_mode_active != 0
        }
        guard ok else { return nil }
        var effects: [FocusEffect] = []
        effects.reserveCapacity(replyEffects.count)
        for effect in replyEffects {
            switch effect.kind {
            case 0: effects.append(.select(pane: string(effect.pane) ?? "", tab: string(effect.tab) ?? ""))
            case 1: effects.append(.revealPane(string(effect.pane) ?? ""))
            case 2: effects.append(.moveResponder(Self.resolved(effect.resolved, string)))
            case 3: effects.append(.publishContext(.init(bits: effect.context)))
            default: effects.append(.browserFocusMode(tab: string(effect.tab) ?? "", active: effect.active != 0))
            }
        }
        return (changed, effects)
    }

    /// The strings of a list the machine returned. The caller vouches that
    /// `list` is nil or the list of the call it just made on the handle.
    @unsafe
    private static func strings(_ list: UnsafePointer<CmuxFocusStrings>?) -> [String?] {
        // SAFETY: the caller's contract: `list` is nil or live, with count items and bytes_len bytes
        // (cmux_layout_reducer_ffi.h); both are copied out before anything else runs.
        guard let list = unsafe list?.pointee else { return [] }
        let items = unsafe copy(list.items, count: list.count)
        let bytes = unsafe copy(list.bytes, count: list.bytes_len)
        return items.map { string($0, in: bytes) }
    }

    /// The `count` elements at `start` as an array (none for nil). The caller
    /// vouches that `start` is nil or readable for `count` elements.
    @unsafe
    private static func copy<Element>(_ start: UnsafePointer<Element>?, count: UInt32) -> [Element] {
        // SAFETY: the caller's contract: `start` is nil or points to `count` readable elements.
        guard let start = unsafe start, count > 0 else { return [] }
        return unsafe Array(UnsafeBufferPointer(start: start, count: Int(count)))
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

    /// The string at `range` of a reply's string table; nil for the absent
    /// range or one past the table's end.
    private static func string(_ range: CmuxFocusStr, in bytes: [UInt8]) -> String? {
        let start = Int(range.offset), end = Int(range.offset) + Int(range.len)
        guard range.offset != UInt32.max, end <= bytes.count else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
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
