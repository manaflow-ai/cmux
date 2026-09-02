public import Foundation

/// Stateful strip of `ESC k … ESC \\` across chunk boundaries.
///
/// Twin of plugin ``TitleEscapeFilter`` / tmux ``RemoteTmuxScreenTitleFilter``.
/// Ghostty is xterm-style and would paint a screen title onto the grid.
public struct RemoteHerdrTitleEscapeFilter: Sendable {
    private enum State: Sendable {
        case text
        case esc
        case title
        case titleEsc
    }

    private var state: State = .text

    /// Creates a filter with no held escape state.
    public init() {}

    /// Drops held escape state (full-redraw / new snapshot).
    public mutating func reset() {
        state = .text
    }

    /// Returns `data` with title sequences removed.
    public mutating func filter(_ data: Data) -> Data {
        if data.isEmpty { return data }
        if state == .text, !data.contains(0x1b) { return data }
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1b {
                    state = .esc
                } else {
                    out.append(byte)
                }
            case .esc:
                if byte == UInt8(ascii: "k") {
                    state = .title
                } else if byte == 0x1b {
                    out.append(0x1b)
                } else {
                    out.append(0x1b)
                    out.append(byte)
                    state = .text
                }
            case .title:
                if byte == 0x1b {
                    state = .titleEsc
                }
            case .titleEsc:
                if byte == 0x5c {
                    state = .text
                } else if byte != 0x1b {
                    state = .title
                }
            }
        }
        return Data(out)
    }
}

/// One isolated write to a single pane surface.
public struct RemoteHerdrSurfaceWrite: Hashable, Sendable {
    /// Herdr pane that produced the bytes.
    public var paneID: String
    /// Host surface id.
    public var surfaceID: String
    /// Bytes actually written (title escapes already stripped).
    public var data: Data
    /// True when the host must replace the buffer instead of appending.
    public var fullRedraw: Bool

    /// Creates a surface write.
    public init(paneID: String, surfaceID: String, data: Data, fullRedraw: Bool = false) {
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.data = data
        self.fullRedraw = fullRedraw
    }
}

/// Typed bytes destined for exactly one Herdr pane.
public struct RemoteHerdrInputSend: Hashable, Sendable {
    /// Target pane.
    public var paneID: String
    /// Key bytes.
    public var data: Data

    /// Creates an input send.
    public init(paneID: String, data: Data) {
        self.paneID = paneID
        self.data = data
    }
}

/// Result of projecting focus (provider event or user click).
public struct RemoteHerdrFocusProjection: Hashable, Sendable {
    /// Pane that is now active, if any.
    public var paneID: String?
    /// True only for a user click that must call `pane.focus`.
    public var sendToProvider: Bool
    /// Whether local active pane changed.
    public var changed: Bool
    /// `provider` or `user`.
    public var source: String

    /// Creates a focus projection.
    public init(paneID: String?, sendToProvider: Bool, changed: Bool, source: String) {
        self.paneID = paneID
        self.sendToProvider = sendToProvider
        self.changed = changed
        self.source = source
    }
}

/// Tab working-directory update (only the active pane may apply it).
public struct RemoteHerdrCwdUpdate: Hashable, Sendable {
    /// Reporting pane.
    public var paneID: String
    /// Owning tab.
    public var tabID: String
    /// Path.
    public var path: String
    /// False when a background pane reported `cd`.
    public var applyToTab: Bool

    /// Creates a cwd update.
    public init(paneID: String, tabID: String, path: String, applyToTab: Bool) {
        self.paneID = paneID
        self.tabID = tabID
        self.path = path
        self.applyToTab = applyToTab
    }
}

/// In-memory I/O router proving tmux isolation without Ghostty.
///
/// Unknown panes are a no-op. Output never crosses panes. Provider
/// focus never echoes ``pane.focus``.
public struct RemoteHerdrPaneRoute: Sendable {
    /// pane id → surface id.
    public var surfaces: [String: String] = [:]
    /// surface id → written bytes.
    public var buffers: [String: Data] = [:]
    /// Last painted ``pane.read`` snapshot per pane.
    public var lastSnapshot: [String: String] = [:]
    /// Per-pane title filters (stateful across chunks).
    public var titleFilters: [String: RemoteHerdrTitleEscapeFilter] = [:]
    /// BASE pane set (zoom-hidden panes stay live).
    public var livePaneIDs: Set<String> = []
    /// Last-known cwd per pane.
    public var cwdByPane: [String: String] = [:]
    /// Locally projected active pane.
    public var activePaneID: String?
    /// In-flight user focus awaiting provider echo.
    public var pendingUserFocus: String?
    /// Apply log for tests. Bounded in production to avoid unbounded growth.
    public var log: [String] = []
    /// When false, ``log`` appends are no-ops (production session hosts).
    public var loggingEnabled = true
    private static let maxLogEntries = 256

    /// Creates an empty router.
    public init(loggingEnabled: Bool = true) {
        self.loggingEnabled = loggingEnabled
    }

    private mutating func appendLog(_ entry: String) {
        guard loggingEnabled else { return }
        log.append(entry)
        if log.count > Self.maxLogEntries {
            log.removeFirst(log.count - Self.maxLogEntries)
        }
    }

    /// Records a host surface for `paneID` (tmux ``panelsByPaneId``).
    public mutating func bind(paneID: String, surfaceID: String) {
        surfaces[paneID] = surfaceID
        if buffers[surfaceID] == nil {
            buffers[surfaceID] = Data()
        }
        livePaneIDs.insert(paneID)
        if titleFilters[paneID] == nil {
            titleFilters[paneID] = RemoteHerdrTitleEscapeFilter()
        }
        appendLog("bind:\(paneID):\(surfaceID)")
    }

    /// Drops the surface binding when the BASE pane is gone.
    public mutating func unbind(paneID: String) {
        if let surfaceID = surfaces.removeValue(forKey: paneID) {
            buffers.removeValue(forKey: surfaceID)
        }
        lastSnapshot.removeValue(forKey: paneID)
        titleFilters.removeValue(forKey: paneID)
        cwdByPane.removeValue(forKey: paneID)
        livePaneIDs.remove(paneID)
        if activePaneID == paneID { activePaneID = nil }
        if pendingUserFocus == paneID { pendingUserFocus = nil }
        appendLog("unbind:\(paneID)")
    }

    /// Replaces the BASE pane set.
    public mutating func setLivePanes(_ paneIDs: [String]) {
        livePaneIDs = Set(paneIDs)
    }

    /// Routes a `%output`-style chunk to exactly one surface.
    ///
    /// Unknown panes are a no-op. Empty data is a no-op.
    public mutating func routeOutput(paneID: String, data: Data) -> RemoteHerdrSurfaceWrite? {
        guard let surfaceID = surfaces[paneID], !data.isEmpty else { return nil }
        var filter = titleFilters[paneID] ?? RemoteHerdrTitleEscapeFilter()
        let cleaned = filter.filter(data)
        titleFilters[paneID] = filter
        if cleaned.isEmpty { return nil }
        var buffer = buffers[surfaceID] ?? Data()
        buffer.append(cleaned)
        buffers[surfaceID] = buffer
        appendLog("out:\(paneID):\(cleaned.count)")
        return RemoteHerdrSurfaceWrite(
            paneID: paneID, surfaceID: surfaceID, data: cleaned, fullRedraw: false
        )
    }

    /// Incremental ``pane.read`` paint (plugin stand-in for `%output`).
    public mutating func routeOutputText(paneID: String, current: String) -> RemoteHerdrSurfaceWrite? {
        guard let surfaceID = surfaces[paneID] else { return nil }
        let previous = lastSnapshot[paneID]
        let (delta, _) = RemoteHerdrOutput.delta(previous: previous, current: current)
        lastSnapshot[paneID] = current
        if delta.chunk.isEmpty, !delta.fullRedraw { return nil }
        var filter = titleFilters[paneID] ?? RemoteHerdrTitleEscapeFilter()
        if delta.fullRedraw {
            filter.reset()
        }
        let cleaned = filter.filter(Data(delta.chunk.utf8))
        titleFilters[paneID] = filter
        if delta.fullRedraw {
            buffers[surfaceID] = cleaned
        } else {
            if cleaned.isEmpty { return nil }
            var buffer = buffers[surfaceID] ?? Data()
            buffer.append(cleaned)
            buffers[surfaceID] = buffer
        }
        appendLog("out-text:\(paneID):redraw=\(delta.fullRedraw ? 1 : 0):\(cleaned.count)")
        return RemoteHerdrSurfaceWrite(
            paneID: paneID, surfaceID: surfaceID, data: cleaned, fullRedraw: delta.fullRedraw
        )
    }

    /// Forwards typed bytes to the bound pane only.
    public mutating func routeInput(paneID: String, data: Data) -> RemoteHerdrInputSend? {
        guard !data.isEmpty, surfaces[paneID] != nil else { return nil }
        appendLog("in:\(paneID):\(data.count)")
        return RemoteHerdrInputSend(paneID: paneID, data: data)
    }

    /// Sends to the active pane only. No-op when focus is unknown.
    public mutating func routeInputToFocus(_ data: Data) -> RemoteHerdrInputSend? {
        guard let activePaneID else { return nil }
        return routeInput(paneID: activePaneID, data: data)
    }

    /// Provider focus. Always projects locally. Never sends `pane.focus`.
    public mutating func noteRemoteActive(paneID: String) -> RemoteHerdrFocusProjection {
        let changed = activePaneID != paneID
        activePaneID = paneID
        if pendingUserFocus == paneID {
            pendingUserFocus = nil
        }
        appendLog("focus-provider:\(paneID)")
        return RemoteHerdrFocusProjection(
            paneID: paneID, sendToProvider: false, changed: changed, source: "provider"
        )
    }

    /// User click. Requires a live BASE pane. Sends unless already pending.
    public mutating func userFocus(paneID: String) -> RemoteHerdrFocusProjection {
        if !livePaneIDs.contains(paneID), surfaces[paneID] == nil {
            appendLog("focus-user-unknown:\(paneID)")
            return RemoteHerdrFocusProjection(
                paneID: nil, sendToProvider: false, changed: false, source: "user"
            )
        }
        let changed = activePaneID != paneID
        activePaneID = paneID
        if pendingUserFocus == paneID {
            appendLog("focus-user-pending:\(paneID)")
            return RemoteHerdrFocusProjection(
                paneID: paneID, sendToProvider: false, changed: changed, source: "user"
            )
        }
        pendingUserFocus = paneID
        appendLog("focus-user-send:\(paneID)")
        return RemoteHerdrFocusProjection(
            paneID: paneID, sendToProvider: true, changed: changed, source: "user"
        )
    }

    /// Dispatch focus by source. Provider never echoes; user may send.
    public mutating func projectFocus(paneID: String, fromProvider: Bool) -> RemoteHerdrFocusProjection {
        if fromProvider {
            return noteRemoteActive(paneID: paneID)
        }
        return userFocus(paneID: paneID)
    }

    /// Cache cwd; apply to the tab only when this pane is active.
    public mutating func routeCwd(paneID: String, path: String, tabID: String) -> RemoteHerdrCwdUpdate? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        cwdByPane[paneID] = trimmed
        let apply = activePaneID == paneID
        appendLog("cwd:\(paneID):tab=\(apply ? 1 : 0)")
        return RemoteHerdrCwdUpdate(paneID: paneID, tabID: tabID, path: trimmed, applyToTab: apply)
    }

    /// Bytes written to `paneID`'s surface (empty if unbound).
    public func buffer(for paneID: String) -> Data {
        guard let surfaceID = surfaces[paneID] else { return Data() }
        return buffers[surfaceID] ?? Data()
    }
}
