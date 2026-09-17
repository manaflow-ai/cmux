public import Foundation

/// Twin of plugin ``cmux_herdr_control``.
///
/// Named keys, input budget, optimistic focus + rollback, adjacent
/// navigation, user split, pane seed, tab activity, busy-close, and
/// inbound session title. No SSH / ``tmux -CC`` / ``respawn-pane``.
public enum RemoteHerdrControl {
    public static let inputBudget = 256 * 1024
    public static let seedBudget = 256 * 1024

    private static let namedCSI: [String: [UInt8]] = [
        "Up": [0x1b, 0x5b, 0x41],
        "Down": [0x1b, 0x5b, 0x42],
        "Right": [0x1b, 0x5b, 0x43],
        "Left": [0x1b, 0x5b, 0x44],
        "Home": [0x1b, 0x5b, 0x48],
        "End": [0x1b, 0x5b, 0x46],
        "PPage": [0x1b, 0x5b, 0x35, 0x7e],
        "NPage": [0x1b, 0x5b, 0x36, 0x7e],
        "DC": [0x1b, 0x5b, 0x33, 0x7e],
        "IC": [0x1b, 0x5b, 0x32, 0x7e],
        "F1": [0x1b, 0x4f, 0x50],
        "F2": [0x1b, 0x4f, 0x51],
        "F3": [0x1b, 0x4f, 0x52],
        "F4": [0x1b, 0x4f, 0x53],
        "F5": [0x1b, 0x5b, 0x31, 0x35, 0x7e],
        "F6": [0x1b, 0x5b, 0x31, 0x37, 0x7e],
        "F7": [0x1b, 0x5b, 0x31, 0x38, 0x7e],
        "F8": [0x1b, 0x5b, 0x31, 0x39, 0x7e],
        "F9": [0x1b, 0x5b, 0x32, 0x30, 0x7e],
        "F10": [0x1b, 0x5b, 0x32, 0x31, 0x7e],
        "F11": [0x1b, 0x5b, 0x32, 0x33, 0x7e],
        "F12": [0x1b, 0x5b, 0x32, 0x34, 0x7e],
    ]

    private static let busyStatuses: Set<String> = [
        "working", "blocked", "running", "command",
    ]

    /// Resolve a tmux-style key name (``C-Up``, ``F5``) for Herdr.
    ///
    /// Unknown names fail closed — never invent a key.
    public static func encodeNamedKey(paneID: String, rawName: String) -> RemoteHerdrProviderInput? {
        guard !paneID.isEmpty, !rawName.isEmpty else { return nil }
        let parts = rawName.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        guard let base = parts.last else { return nil }
        let mods = Set(parts.dropLast().filter { $0 == "C" || $0 == "M" || $0 == "S" })
        guard var csi = namedCSI[base] else { return nil }
        if !mods.isEmpty {
            csi = csiWithModifiers(base: base, csi: csi, mods: mods)
        }
        let key = (mods.sorted() + [base]).joined(separator: "-")
        return RemoteHerdrProviderInput(paneID: paneID, kind: "key", key: key, csi: Data(csi))
    }

    /// Build one Ghostty-style manual input. Key wins over text.
    public static func encodeManualInput(
        paneID: String,
        text: String? = nil,
        key: String? = nil
    ) -> RemoteHerdrProviderInput? {
        if let key {
            return encodeNamedKey(paneID: paneID, rawName: key)
        }
        if let text, !text.isEmpty {
            return RemoteHerdrProviderInput(paneID: paneID, kind: "text", text: text)
        }
        return nil
    }

    /// User chrome split → ``pane.split``.
    public static func requestSplit(
        fromPaneID: String,
        vertical: Bool,
        insertFirst: Bool = false,
        focusCreated: Bool = true
    ) -> RemoteHerdrUserSplit? {
        guard !fromPaneID.isEmpty else { return nil }
        return RemoteHerdrUserSplit(
            fromPaneID: fromPaneID,
            orientation: vertical ? "vertical" : "horizontal",
            insertFirst: insertFirst,
            focusCreated: focusCreated
        )
    }

    /// Neighbor leaf in the layout tree (tmux ``navigateFocus``).
    public static func adjacentPane(
        _ node: RemoteHerdrLayoutNode,
        paneID: String,
        direction: String
    ) -> String? {
        guard let path = pathToPane(node, paneID: paneID) else { return nil }
        let wantHorizontal = direction == "left" || direction == "right"
        if path.count < 2 { return nil }
        for index in stride(from: path.count - 1, through: 1, by: -1) {
            let parent = path[index - 1]
            let child = path[index]
            let axisOK = parent.isHorizontal == wantHorizontal
            guard axisOK, !parent.isPane, let children = parent.children else { continue }
            guard let childIndex = children.firstIndex(of: child) else { continue }
            if (direction == "left" || direction == "up"), childIndex > 0 {
                return edgePane(children[childIndex - 1], approaching: direction)
            }
            if (direction == "right" || direction == "down"), childIndex + 1 < children.count {
                return edgePane(children[childIndex + 1], approaching: direction)
            }
        }
        return nil
    }

    /// Project pane statuses onto tab activity.
    public static func tabActivity(
        statuses: [String: String],
        agents: [String: String] = [:]
    ) -> RemoteHerdrTabActivity {
        let busy = statuses.compactMap { paneID, status -> String? in
            busyStatuses.contains(status.lowercased()) ? paneID : nil
        }.sorted()
        let command = busy.compactMap { agents[$0] }.first
        return RemoteHerdrTabActivity(
            hasActiveCommand: !busy.isEmpty,
            activeCommandName: command,
            needsCloseConfirmation: !busy.isEmpty
        )
    }

    /// Host close never kills Herdr. User pane close may confirm when busy.
    public static func closeIntent(
        source: String,
        paneID: String? = nil,
        agentStatus: String? = nil
    ) -> RemoteHerdrCloseIntent {
        if ["host_tab", "host_panel", "detach"].contains(source) {
            return RemoteHerdrCloseIntent(action: "detach")
        }
        guard source == "user_pane", let paneID, !paneID.isEmpty else {
            return RemoteHerdrCloseIntent(action: "noop")
        }
        if let agentStatus, busyStatuses.contains(agentStatus.lowercased()) {
            return RemoteHerdrCloseIntent(action: "confirm_then_close_pane", paneID: paneID)
        }
        return RemoteHerdrCloseIntent(action: "close_pane", paneID: paneID)
    }

    /// Inbound session/tab rename. ``propagateToProvider`` must stay false.
    public static func applySessionTitle(
        _ name: String,
        current: String? = nil,
        propagateToProvider: Bool = false
    ) -> String? {
        if propagateToProvider { return nil }
        let cleaned = String(name.unicodeScalars.filter { $0.isASCII && $0.value >= 32 && $0.value != 127 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == current { return nil }
        return String(cleaned.prefix(200))
    }

    /// Observability rows (tmux ``remote.tmux.pane_surfaces``).
    public static func paneSurfaceEntries(
        _ bindings: [(tabID: String, paneID: String, surfaceID: String, onScreen: Bool)]
    ) -> [[String: Any]] {
        bindings
            .sorted { lhs, rhs in
                if lhs.tabID != rhs.tabID { return lhs.tabID < rhs.tabID }
                return lhs.paneID < rhs.paneID
            }
            .map { row in
                [
                    "tab_id": row.tabID,
                    "pane_id": row.paneID,
                    "surface_id": row.surfaceID,
                    "on_screen": row.onScreen,
                ]
            }
    }

    private static func csiWithModifiers(base: String, csi: [UInt8], mods: Set<String>) -> [UInt8] {
        var code = 1
        if mods.contains("S") { code += 1 }
        if mods.contains("M") { code += 2 }
        if mods.contains("C") { code += 4 }
        if code == 1 { return csi }
        if csi.last == 0x7e {
            let core = Array(csi.dropFirst(2).dropLast())
            return [0x1b, 0x5b] + core + Array(";\(code)~".utf8)
        }
        if csi.count == 3, csi[0] == 0x1b, csi[1] == 0x4f {
            let letter: [UInt8]?
            switch csi[2] {
            case 0x50: letter = Array("11".utf8)
            case 0x51: letter = Array("12".utf8)
            case 0x52: letter = Array("13".utf8)
            case 0x53: letter = Array("14".utf8)
            default: letter = nil
            }
            if let letter {
                return [0x1b, 0x5b] + letter + Array(";\(code)~".utf8)
            }
        }
        if csi.count == 3, csi[0] == 0x1b, csi[1] == 0x5b {
            return [0x1b, 0x5b, 0x31, 0x3b] + Array(String(code).utf8) + [csi[2]]
        }
        return csi
    }

    private static func pathToPane(
        _ node: RemoteHerdrLayoutNode,
        paneID: String
    ) -> [RemoteHerdrLayoutNode]? {
        if node.isPane {
            return node.paneID == paneID ? [node] : nil
        }
        for child in node.children ?? [] {
            if let found = pathToPane(child, paneID: paneID) {
                return [node] + found
            }
        }
        return nil
    }

    private static func edgePane(_ node: RemoteHerdrLayoutNode, approaching: String) -> String? {
        if node.isPane { return node.paneID }
        guard let children = node.children, let first = children.first else { return nil }
        if approaching == "left", node.isHorizontal, let last = children.last {
            return edgePane(last, approaching: approaching)
        }
        if approaching == "up", node.isVertical, let last = children.last {
            return edgePane(last, approaching: approaching)
        }
        return edgePane(first, approaching: approaching)
    }
}

/// One input event for a single Herdr pane (tmux ``TerminalManualInput``).
public struct RemoteHerdrProviderInput: Hashable, Sendable {
    public var paneID: String
    public var kind: String
    public var text: String?
    public var key: String?
    public var csi: Data?

    public init(
        paneID: String,
        kind: String,
        text: String? = nil,
        key: String? = nil,
        csi: Data? = nil
    ) {
        self.paneID = paneID
        self.kind = kind
        self.text = text
        self.key = key
        self.csi = csi
    }

    public var byteCount: Int {
        if kind == "key" {
            return max(1, csi?.count ?? 0)
        }
        return max(1, text?.utf8.count ?? 0)
    }
}

/// Bounded Ghostty→Herdr input queue.
///
/// Isolation: callers must touch this type only from the main actor (host
/// Ghostty / session-host paths). `@unchecked Sendable` documents that
/// invariant so the type can cross async boundaries without introducing
/// a package-level `@MainActor` dependency.
public final class RemoteHerdrInputForwarder: @unchecked Sendable {
    public var maximumPendingBytes: Int
    public var pendingBytes = 0
    public var epoch = 0
    public var active = true
    public var overflowed = false
    public var queue: [RemoteHerdrProviderInput] = []

    public init(maximumPendingBytes: Int = RemoteHerdrControl.inputBudget) {
        self.maximumPendingBytes = maximumPendingBytes
    }

    public func enqueue(_ item: RemoteHerdrProviderInput) -> String {
        guard active else { return "inactive" }
        if pendingBytes + item.byteCount > maximumPendingBytes {
            overflowed = true
            return "overflow"
        }
        pendingBytes += item.byteCount
        queue.append(item)
        return "enqueued"
    }

    public func drain() -> [RemoteHerdrProviderInput] {
        let items = queue
        queue.removeAll()
        pendingBytes = 0
        return items
    }

    public func deactivate() {
        active = false
        epoch += 1
        queue.removeAll()
        pendingBytes = 0
    }
}

/// Optimistic user focus with rollback.
///
/// Isolation: main-actor only (same as ``RemoteHerdrInputForwarder``).
public final class RemoteHerdrFocusController: @unchecked Sendable {
    public var livePaneIDs: [String] = []
    public var activePaneID: String?
    public var pending: (requestID: String, paneID: String, previousPaneID: String?)?
    private var nextID = 0

    public init() {}

    public func userSelect(_ paneID: String) -> RemoteHerdrFocusCommand {
        guard livePaneIDs.contains(paneID) else {
            return RemoteHerdrFocusCommand(paneID: nil, sendToProvider: false)
        }
        if let pending, pending.paneID == paneID {
            return RemoteHerdrFocusCommand(
                paneID: paneID,
                sendToProvider: false,
                requestID: pending.requestID
            )
        }
        nextID += 1
        let requestID = "f\(nextID)"
        pending = (requestID, paneID, activePaneID)
        activePaneID = paneID
        return RemoteHerdrFocusCommand(paneID: paneID, sendToProvider: true, requestID: requestID)
    }

    public func commandRejected(_ requestID: String) -> RemoteHerdrFocusCommand {
        guard let pending, pending.requestID == requestID else {
            return RemoteHerdrFocusCommand(paneID: activePaneID, sendToProvider: false)
        }
        self.pending = nil
        activePaneID = pending.previousPaneID
        return RemoteHerdrFocusCommand(
            paneID: pending.previousPaneID,
            sendToProvider: false,
            rolledBack: true,
            requestID: requestID
        )
    }

    public func providerConfirms(_ paneID: String) -> RemoteHerdrFocusCommand {
        if pending?.paneID == paneID {
            pending = nil
        }
        activePaneID = paneID
        return RemoteHerdrFocusCommand(paneID: paneID, sendToProvider: false)
    }
}

public struct RemoteHerdrFocusCommand: Hashable, Sendable {
    public var paneID: String?
    public var sendToProvider: Bool
    public var rolledBack: Bool
    public var requestID: String?

    public init(
        paneID: String?,
        sendToProvider: Bool,
        rolledBack: Bool = false,
        requestID: String? = nil
    ) {
        self.paneID = paneID
        self.sendToProvider = sendToProvider
        self.rolledBack = rolledBack
        self.requestID = requestID
    }
}

/// Hold ``pane.read`` seed bytes until the surface grid is ready.
///
/// Isolation: main-actor only (same as ``RemoteHerdrInputForwarder``).
public final class RemoteHerdrPaneSeedQueue: @unchecked Sendable {
    public var maximumBytes: Int
    public var pending: [String: Data] = [:]
    public var kinds: [String: String] = [:]
    public var targets: [String: (Int, Int)] = [:]
    public var deferredFull: Set<String> = []

    public init(maximumBytes: Int = RemoteHerdrControl.seedBudget) {
        self.maximumBytes = maximumBytes
    }

    public func queue(
        paneID: String,
        data: Data,
        kind: String = "full",
        targetGrid: (Int, Int)? = nil
    ) -> String {
        guard !data.isEmpty else { return "empty" }
        if data.count > maximumBytes {
            deferredFull.insert(paneID)
            pending.removeValue(forKey: paneID)
            kinds.removeValue(forKey: paneID)
            targets.removeValue(forKey: paneID)
            return "overflow"
        }
        pending[paneID] = data
        kinds[paneID] = kind
        if let targetGrid {
            targets[paneID] = targetGrid
        }
        return "queued"
    }

    public func noteReady(paneID: String, cols: Int, rows: Int) -> Data? {
        if let target = targets[paneID], target != (cols, rows) {
            return nil
        }
        let data = pending.removeValue(forKey: paneID)
        kinds.removeValue(forKey: paneID)
        targets.removeValue(forKey: paneID)
        if data != nil {
            deferredFull.remove(paneID)
        }
        return data
    }
}

public struct RemoteHerdrUserSplit: Hashable, Sendable {
    public var fromPaneID: String
    public var orientation: String
    public var insertFirst: Bool
    public var focusCreated: Bool

    public init(
        fromPaneID: String,
        orientation: String,
        insertFirst: Bool = false,
        focusCreated: Bool = true
    ) {
        self.fromPaneID = fromPaneID
        self.orientation = orientation
        self.insertFirst = insertFirst
        self.focusCreated = focusCreated
    }
}

public struct RemoteHerdrTabActivity: Hashable, Sendable {
    public var hasActiveCommand: Bool
    public var activeCommandName: String?
    public var needsCloseConfirmation: Bool

    public init(
        hasActiveCommand: Bool,
        activeCommandName: String?,
        needsCloseConfirmation: Bool
    ) {
        self.hasActiveCommand = hasActiveCommand
        self.activeCommandName = activeCommandName
        self.needsCloseConfirmation = needsCloseConfirmation
    }
}

public struct RemoteHerdrCloseIntent: Hashable, Sendable {
    public var action: String
    public var paneID: String?

    public init(action: String, paneID: String? = nil) {
        self.action = action
        self.paneID = paneID
    }
}

extension RemoteHerdrLayoutNode {
    /// True when this node is a leaf pane.
    public var isPane: Bool {
        if case .pane = content { return true }
        return false
    }

    /// True when this node is a horizontal split.
    public var isHorizontal: Bool {
        if case .horizontal = content { return true }
        return false
    }

    /// True when this node is a vertical split.
    public var isVertical: Bool {
        if case .vertical = content { return true }
        return false
    }

    /// Leaf pane id when this node is a pane.
    public var paneID: String? {
        if case let .pane(id) = content { return id }
        return nil
    }

    /// Split children when this node is a split.
    public var children: [RemoteHerdrLayoutNode]? {
        switch content {
        case .pane:
            return nil
        case let .horizontal(nodes), let .vertical(nodes):
            return nodes
        }
    }
}
