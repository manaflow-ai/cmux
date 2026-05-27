import Foundation
import AppKit

enum TmuxControlEvent: Equatable, Sendable {
    case enter
    case exit
    case windowsChanged(Data)
    case paneOutput(paneId: UInt32, data: Data)
}

struct TmuxControlLayoutNode: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    let pane: UInt32?
    let horizontal: [TmuxControlLayoutNode]?
    let vertical: [TmuxControlLayoutNode]?

    var paneIds: [UInt32] {
        if let pane { return [pane] }
        return (horizontal ?? []).flatMap(\.paneIds) + (vertical ?? []).flatMap(\.paneIds)
    }

    var debugPayload: [String: Any] {
        var payload: [String: Any] = [
            "width": width,
            "height": height,
            "x": x,
            "y": y
        ]
        if let pane {
            payload["pane"] = pane
        }
        if let horizontal {
            payload["horizontal"] = horizontal.map(\.debugPayload)
        }
        if let vertical {
            payload["vertical"] = vertical.map(\.debugPayload)
        }
        return payload
    }
}

struct TmuxControlWindow: Codable, Equatable, Sendable {
    let id: Int
    let width: Int
    let height: Int
    let layout: TmuxControlLayoutNode

    var paneIds: [UInt32] {
        layout.paneIds
    }

    var debugPayload: [String: Any] {
        [
            "id": id,
            "width": width,
            "height": height,
            "pane_ids": paneIds,
            "layout": layout.debugPayload
        ]
    }
}

struct TmuxControlTopology: Codable, Equatable, Sendable {
    let sessionId: Int
    let tmuxVersion: String
    let paneIds: [UInt32]
    let windows: [TmuxControlWindow]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case tmuxVersion = "tmux_version"
        case paneIds = "pane_ids"
        case windows
    }
}

struct TmuxControlState: Equatable, Sendable {
    private static let paneTextByteLimit = 65_536

    var active = false
    var lastEvent = "inactive"
    var sessionId: Int?
    var tmuxVersion: String?
    var paneIds: [UInt32] = []
    var windows: [TmuxControlWindow] = []
    var paneBytesById: [UInt32: Data] = [:]
    var lastPaneOutputId: UInt32?
    var topologyParseError: String?

    mutating func apply(_ event: TmuxControlEvent) {
        switch event {
        case .enter:
            self = TmuxControlState(
                active: true,
                lastEvent: "enter"
            )
        case .exit:
            self = TmuxControlState(lastEvent: "exit")
        case .windowsChanged(let data):
            active = true
            lastEvent = "windows_changed"
            do {
                let topology = try JSONDecoder().decode(TmuxControlTopology.self, from: data)
                sessionId = topology.sessionId
                tmuxVersion = topology.tmuxVersion
                windows = topology.windows
                let layoutPaneIds = topology.windows.flatMap(\.paneIds)
                let ids = topology.paneIds.isEmpty ? layoutPaneIds : topology.paneIds
                paneIds = Array(Set(ids)).sorted()
                paneBytesById = paneBytesById.filter { paneIds.contains($0.key) }
                topologyParseError = nil
            } catch {
                topologyParseError = "json_decode_failed"
#if DEBUG
                cmuxDebugLog("tmux.control topology decode failed: \(String(describing: error))")
#endif
            }
        case .paneOutput(let paneId, let chunk):
            active = true
            lastEvent = "pane_output"
            lastPaneOutputId = paneId
            if !paneIds.contains(paneId) {
                paneIds.append(paneId)
                paneIds.sort()
            }
            var combined = paneBytesById[paneId] ?? Data()
            combined.append(chunk)
            if combined.count > Self.paneTextByteLimit {
                paneBytesById[paneId] = Data(combined.suffix(Self.paneTextByteLimit))
            } else {
                paneBytesById[paneId] = combined
            }
        }
    }

    func debugPayload(includePaneText: Bool = false) -> [String: Any] {
        var payload: [String: Any] = [
            "active": active,
            "last_event": lastEvent,
            "session_id": sessionId.map { $0 as Any } ?? NSNull(),
            "tmux_version": tmuxVersion ?? NSNull(),
            "pane_ids": paneIds,
            "windows": windows.map(\.debugPayload),
            "panes": paneIds.map { ["id": $0] },
            "last_pane_output_id": lastPaneOutputId.map { $0 as Any } ?? NSNull(),
            "topology_parse_error": topologyParseError ?? NSNull()
        ]

        if includePaneText {
            payload["panes"] = paneIds.map { paneId in
                [
                    "id": paneId,
                    "text": Self.decodedPaneText(from: paneBytesById[paneId] ?? Data())
                ]
            }
        }

        return payload
    }

    private static func decodedPaneText(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        let maxLeadingDrop = min(3, data.count)
        for leadingDrop in 0...maxLeadingDrop {
            let leadingTrimmed = data.dropFirst(leadingDrop)
            let maxTrailingDrop = min(3, leadingTrimmed.count)
            for trailingDrop in 0...maxTrailingDrop where leadingDrop != 0 || trailingDrop != 0 {
                let candidate = leadingTrimmed.dropLast(trailingDrop)
                if let string = String(data: Data(candidate), encoding: .utf8) {
                    return string
                }
            }
        }

        return String(decoding: data, as: UTF8.self)
    }
}

final class GhosttyPassthroughVisualEffectView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

func shouldAllowEnsureFocusWindowActivation(
    activeTabManager: TabManager?,
    targetTabManager: TabManager,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?,
    targetWindow: NSWindow
) -> Bool {
    guard activeTabManager === targetTabManager || (keyWindow == nil && mainWindow == nil) else {
        return false
    }

    if let keyWindow {
        return keyWindow === targetWindow
    }

    if let mainWindow {
        return mainWindow === targetWindow
    }

    return true
}

extension TerminalSurface {
    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugTmuxStartCommand() -> String? {
        tmuxStartCommand
    }

    func debugInitialInputMetadata() -> (hasInitialInput: Bool, byteCount: Int) {
        let byteCount = initialInput?.utf8.count ?? 0
        return (byteCount > 0, byteCount)
    }

    func debugInitialInputForTesting() -> String? {
        initialInput
    }
}
