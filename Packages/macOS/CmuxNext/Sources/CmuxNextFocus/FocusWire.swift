import CCmuxLayoutReducerFFI

/// The string table of one request to the focus machine (`FocusMachine`).
nonisolated struct FocusWire {
    static let absent = CmuxFocusStr(offset: UInt32.max, len: 0)

    var bytes: [UInt8] = []
    var list: [CmuxFocusStr] = []

    mutating func put(_ text: String?) -> CmuxFocusStr {
        guard let text else { return Self.absent }
        let offset = UInt32(bytes.count)
        bytes.append(contentsOf: text.utf8)
        return CmuxFocusStr(offset: offset, len: UInt32(bytes.count) - offset)
    }

    /// `event` in `CmuxFocusEvent` form (the header's codes), its strings in
    /// this table. Not for a topology (`cmux_focus_set_topology`).
    mutating func event(_ event: FocusEvent) -> FocusWireEvent {
        var out = FocusWireEvent()
        switch event {
        case .topology:
            out.kind = 255
        case .focusPane(let pane, let workspace, let source):
            out.kind = 0; out.a = put(pane); out.c = put(workspace); out.source = source.code
        case .selectTab(let pane, let tab, let workspace, let source):
            out.kind = 1; out.a = put(pane); out.b = put(tab); out.c = put(workspace); out.source = source.code
        case .focusTarget(let target, let source):
            out.kind = 2; (out.target, out.targetKeyboard) = target.code; out.source = source.code
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
            out.kind = 9; (out.target, out.targetKeyboard) = target.code; out.b = put(awayFrom); out.generation = generation
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

    private mutating func setList(_ tabs: [String], _ out: inout FocusWireEvent) {
        var ranges: [CmuxFocusStr] = []
        for tab in tabs { ranges.append(put(tab)) }
        list = ranges
        out.listCount = UInt32(ranges.count)
    }
}

/// A `CmuxFocusEvent` without its list pointer: the event is built as a plain
/// value, and the pointer to the request's tab list is set only where the
/// call that reads it is made (`encoded(list:)`).
nonisolated struct FocusWireEvent {
    var kind: UInt8 = 0
    var source: UInt8 = 0
    var target: UInt8 = 0
    var targetKeyboard: UInt8 = 0
    var value: UInt8 = 0
    var listCount: UInt32 = 0
    var generation: UInt64 = 0
    var a = FocusWire.absent
    var b = FocusWire.absent
    var c = FocusWire.absent

    /// The C event, with `list` (the request's `listCount` ranges, or nil) as
    /// its list. Valid only while `list` is.
    func encoded(list: UnsafePointer<CmuxFocusStr>?) -> CmuxFocusEvent {
        // SAFETY: stores the caller's pointer without reading it; the caller passes the result only to a call made
        // while `list` is valid.
        unsafe CmuxFocusEvent(kind: kind, source: source, target: target, target_keyboard: targetKeyboard, value: value,
                              reserved: (0, 0, 0), list_count: listCount, reserved2: 0, generation: generation,
                              a: a, b: b, c: c, list: list)
    }
}

// MARK: Codes (cmux_layout_reducer_ffi.h, CMUX_FOCUS_*)

extension FocusEvent.Source {
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

extension FocusState.Target {
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

extension FocusState.Overlay {
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

extension FocusState.Context {
    nonisolated init(bits: UInt8) {
        self.init(terminal: bits & 1 != 0, browser: bits & 2 != 0, agent: bits & 4 != 0)
    }
}

extension FocusTopology.Kind {
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
