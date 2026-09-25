import Foundation

// Wire shapes for the cmux-tui JSON-lines control protocol (protocol v12,
// cmux-tui/spec/commands.md and events.md) and the resource API v2 envelope
// carried on the same socket. Decoders are lenient: unknown fields are ignored
// and additive fields are optional.

/// A JSON value for outbound request parameters.
enum CmuxTUIWireValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case uint(UInt64)
    case double(Double)
    case bool(Bool)
    case strings([String])
    case object([String: CmuxTUIWireValue])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .uint(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension Dictionary where Key == String, Value == CmuxTUIWireValue {
    /// This request object as one newline-terminated JSON line.
    func cmuxTUILine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

extension Decodable {
    /// Decodes one cmux-tui JSON line, reporting failures as
    /// ``CmuxTUIError/malformedResponse(_:)``.
    init(cmuxTUILine data: Data) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CmuxTUIError.malformedResponse("\(Self.self): \(error)")
        }
    }
}

extension Data {
    /// Decodes a base64 wire field; a missing or malformed field is empty.
    init(cmuxTUIBase64 string: String?) {
        guard let string else {
            self.init()
            return
        }
        self = Data(base64Encoded: string) ?? Data()
    }
}

/// Just enough of any line to route it.
struct CmuxTUIRoutingEnvelope: Decodable {
    var id: String?
    var event: String?

    private enum CodingKeys: String, CodingKey { case id, event }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // We only send string ids; tolerate anything else as unroutable.
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        event = try? container.decodeIfPresent(String.self, forKey: .event)
    }
}

struct CmuxTUIEmpty: Decodable, Sendable {}

struct CmuxTUIRawResponse<T: Decodable>: Decodable {
    var ok: Bool
    var data: T?
    var error: String?
    var error_code: String?
}

struct CmuxTUIV2Response<T: Decodable>: Decodable {
    struct Failure: Decodable {
        var code: String
        var message: String
    }
    var ok: Bool
    var result: T?
    var error: Failure?
}

struct CmuxTUIIdentifyWire: Decodable {
    var app: String
    var version: String
    var protocol_: Int
    var capabilities: [String]?
    var session: String
    var pid: Int
    var generation: String?
    var build_commit: String?

    private enum CodingKeys: String, CodingKey {
        case app, version, capabilities, session, pid, generation, build_commit
        case protocol_ = "protocol"
    }
}

struct CmuxTUITreeWire: Decodable {
    struct Workspace: Decodable {
        var id: Int
        var key: String?
        var resource_id: String?
        var name: String
        var active: Bool
        var screens: [Screen]?
    }
    struct Screen: Decodable {
        var id: Int
        var name: String?
        var active_pane: Int?
        var panes: [Pane]?
    }
    struct Pane: Decodable {
        var id: Int
        var name: String?
        var tabs: [Tab]?
    }
    struct Size: Decodable {
        var cols: Int
        var rows: Int
    }
    struct Tab: Decodable {
        var surface: Int
        var kind: String
        var name: String?
        var title: String?
        var size: Size?
        var dead: Bool?
        var terminal_id: String?
        var terminal_resource_id: String?
        var content_resource_id: String?
        var url: String?
        var browser_status: String?
        var browser_error: String?
        var browser_frames_stalled: Bool?
    }
    var workspaces: [Workspace]

    var model: [CmuxTUIWorkspace] {
        workspaces.map { workspace in
            var terminals: [CmuxTUITerminal] = []
            var browsers: [CmuxTUIBrowserTab] = []
            for screen in workspace.screens ?? [] {
                for pane in screen.panes ?? [] {
                    for tab in pane.tabs ?? [] where tab.kind == "browser" {
                        browsers.append(CmuxTUIBrowserTab(
                            surface: tab.surface,
                            pane: pane.id,
                            screen: screen.id,
                            resourceID: tab.content_resource_id,
                            url: tab.url,
                            title: tab.title ?? "",
                            status: tab.browser_status.flatMap(CmuxTUIBrowserStatus.init(rawValue:)),
                            error: tab.browser_error,
                            framesStalled: tab.browser_frames_stalled ?? false,
                            cols: tab.size?.cols,
                            rows: tab.size?.rows,
                            dead: tab.dead ?? false
                        ))
                    }
                    for tab in pane.tabs ?? [] where tab.kind == "pty" {
                        terminals.append(CmuxTUITerminal(
                            surface: tab.surface,
                            pane: pane.id,
                            screen: screen.id,
                            resourceID: tab.terminal_resource_id,
                            terminalID: tab.terminal_id,
                            name: tab.name,
                            title: tab.title ?? "",
                            cols: tab.size?.cols,
                            rows: tab.size?.rows,
                            dead: tab.dead ?? false
                        ))
                    }
                }
            }
            return CmuxTUIWorkspace(
                id: workspace.id,
                key: workspace.key,
                resourceID: workspace.resource_id,
                name: workspace.name,
                active: workspace.active,
                terminals: terminals,
                browsers: browsers,
                screens: (workspace.screens ?? []).map { screen in
                    CmuxTUIScreen(
                        id: screen.id,
                        name: screen.name,
                        activePane: screen.active_pane,
                        panes: (screen.panes ?? []).map { CmuxTUIPane(id: $0.id, name: $0.name) }
                    )
                }
            )
        }
    }
}

struct CmuxTUIWorkspaceMutationWire: Decodable {
    var workspace: Int
    var key: String
}

struct CmuxTUICreateTerminalWire: Decodable {
    var surface: Int?
    var terminal_id: String
    var workspace: Int?
    var key: String
    var lifecycle: String
    var already_exited: Bool?

    var model: CmuxTUICreatedTerminal {
        CmuxTUICreatedTerminal(
            surface: surface,
            terminalID: terminal_id,
            workspace: workspace,
            workspaceKey: key,
            lifecycle: lifecycle,
            alreadyExited: already_exited ?? false
        )
    }
}

struct CmuxTUIAttachResultWire: Decodable {
    var lease: String?
}

struct CmuxTUIOutcomeWire: Decodable {
    var outcome: String?
    var accepted: Bool?
}

struct CmuxTUIResourceIDWire: Decodable {
    var id: String
    var name: String?
}

/// Colors object from `vt-state`/`resized`, or the top level of `colors-changed`.
struct CmuxTUIColorsWire: Decodable {
    var fg: String?
    var bg: String?
    var cursor: String?
    var selection_bg: String?
    var selection_fg: String?
    var palette: [String: String]?
    var cursor_style: String?
    var cursor_blink: Bool?

    var model: CmuxTUITerminalColors {
        var indexed: [Int: String] = [:]
        for (key, value) in palette ?? [:] {
            if let index = Int(key) { indexed[index] = value }
        }
        return CmuxTUITerminalColors(
            foreground: fg,
            background: bg,
            cursor: cursor,
            selectionBackground: selection_bg,
            selectionForeground: selection_fg,
            palette: indexed,
            cursorStyle: cursor_style,
            cursorBlink: cursor_blink
        )
    }
}

struct CmuxTUIEventWire: Decodable {
    var event: String
    var surface: Int?
    var cols: Int?
    var rows: Int?
    var data: String?
    var replay: String?
    var title: String?
    var colors: CmuxTUIColorsWire?
}

/// Splits a byte stream into newline-terminated lines without rescanning.
struct CmuxTUILineBuffer {
    private var buffer = Data()
    private var scanned = 0

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        var index = buffer.startIndex + scanned
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                if index > start { lines.append(buffer.subdata(in: start..<index)) }
                start = index + 1
            }
            index += 1
        }
        if start > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<start)
        }
        scanned = buffer.count
        return lines
    }
}
