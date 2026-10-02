public import AppKit

/// Demo data for the pane: several agents on this Mac, a Mac mini and a
/// Linux VM, live, paused and ended sessions, typed text redacted, one
/// unreachable machine. Frames are drawn on demand. Used by the module demo
/// and Debug Settings screenshots; the App never ships it as real data.
@MainActor
public final class AgentActivityMockSource: AgentActivitySource {
    public private(set) var performed: [AgentActivityUserOp] = []
    private var sink: (@MainActor (AgentActivityUpdate) -> Void)?
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void) {
        self.sink = sink
        var byMachine: [String: [AgentActivitySession]] = [:]
        for session in sessions { byMachine[session.machine, default: []].append(session) }
        for (machine, list) in byMachine.sorted(by: { $0.key < $1.key }) {
            sink(.sessions(machine: machine, list))
        }
        sink(.connection(machine: "build-mini-2", .unreachable))
    }

    public func follow(session: String, _ on: Bool) {
        guard on, let spec = specs.first(where: { $0.id == session }) else { return }
        sink?(.events(session: session, events(for: spec)))
    }

    public func image(for frame: AgentActivityFrameRef) async -> NSImage? {
        let parts = frame.blob.split(separator: "|").map(String.init)
        guard parts.count == 3, let step = Int(parts[2]) else { return nil }
        return Self.drawFrame(app: parts[1], step: step, size: NSSize(width: frame.width, height: frame.height),
                              tint: specs.first { $0.id == parts[0] }?.color ?? "#888888")
    }

    public func perform(_ op: AgentActivityUserOp) async throws {
        performed.append(op)
    }

    // MARK: Data

    private struct Spec {
        let id: String
        let machine: String
        let machineName: String
        let label: String
        let kind: String
        let agent: String
        let attribution: AgentActivityAttribution
        let workspace: String
        let terminal: String
        let color: String
        let apps: [String]
        let status: AgentActivityStatus
        let minutesAgo: Double
        let steps: Int
        let errors: Int
        var foregroundOnly = false
    }

    private var specs: [Spec] {
        [
            Spec(id: "cua_n_01", machine: AgentActivityModel.localMachine, machineName: "This Mac", label: "fill-expense-report",
                 kind: "claude", agent: "Claude Code", attribution: .processTree, workspace: "finance", terminal: "claude · expenses",
                 color: "#E5484D", apps: ["Numbers", "Preview"], status: .active, minutesAgo: 0.2, steps: 28, errors: 1),
            Spec(id: "cua_c_02", machine: AgentActivityModel.localMachine, machineName: "This Mac", label: "codex-safari-repro",
                 kind: "codex", agent: "Codex", attribution: .credential, workspace: "cmux", terminal: "codex · issue 16502",
                 color: "#30A46C", apps: ["Safari"], status: .active, minutesAgo: 1, steps: 16, errors: 0),
            Spec(id: "cua_n_03", machine: AgentActivityModel.localMachine, machineName: "This Mac", label: "figma-export",
                 kind: "mux", agent: "Atlas (mux)", attribution: .credential, workspace: "design", terminal: "mux",
                 color: "#D6409F", apps: ["Figma"], status: .paused, minutesAgo: 6, steps: 9, errors: 0),
            Spec(id: "cua_n_04", machine: AgentActivityModel.localMachine, machineName: "This Mac", label: "settings-probe",
                 kind: "cli", agent: "cmux-cua call", attribution: .none, workspace: "—", terminal: "zsh",
                 color: "#F5A524", apps: ["System Settings"], status: .ended(.userStop), minutesAgo: 42, steps: 5, errors: 2),
            Spec(id: "cua_n_05", machine: AgentActivityModel.localMachine, machineName: "This Mac", label: "calendar-invite",
                 kind: "claude", agent: "Claude Code", attribution: .processTree, workspace: "home", terminal: "claude · calendar",
                 color: "#8E4EC6", apps: ["Calendar", "Mail"], status: .ended(.agentEnd), minutesAgo: 180, steps: 12, errors: 0),
            Spec(id: "cua_n_11", machine: "mini-lawrence", machineName: "mini-lawrence", label: "xcode-archive-check",
                 kind: "codex", agent: "Codex", attribution: .credential, workspace: "ios", terminal: "codex · archive",
                 color: "#12A594", apps: ["Xcode"], status: .idle, minutesAgo: 4, steps: 7, errors: 0),
            Spec(id: "cua_n_21", machine: "vm-dev-12", machineName: "vm-dev-12 (Linux)", label: "gimp-batch",
                 kind: "acp:claude", agent: "Claude (ACP)", attribution: .credential, workspace: "cloud", terminal: "acp · gimp",
                 color: "#F76B15", apps: ["GIMP", "Files"], status: .active, minutesAgo: 0.5, steps: 19, errors: 3),
        ]
    }

    private var sessions: [AgentActivitySession] {
        specs.map { spec in
            let last = now.addingTimeInterval(-spec.minutesAgo * 60)
            let started = last.addingTimeInterval(-Double(spec.steps) * 9)
            let acts = spec.steps * 2 / 3
            return AgentActivitySession(
                id: spec.id, machine: spec.machine, machineName: spec.machineName, label: spec.label, agentKind: spec.kind,
                agentName: spec.agent, attribution: spec.attribution, workspaceTitle: spec.workspace, terminalTitle: spec.terminal,
                colorHex: spec.color, targetApps: spec.apps, status: spec.status, startedAt: started, lastActionAt: last,
                endedAt: spec.status.isLive ? nil : last, acts: acts, observes: spec.steps - acts, errors: spec.errors,
                foregroundOnly: spec.foregroundOnly)
        }
    }

    private func events(for spec: Spec) -> [AgentActivityEvent] {
        let last = now.addingTimeInterval(-spec.minutesAgo * 60)
        let start = last.addingTimeInterval(-Double(spec.steps) * 9)
        var events: [AgentActivityEvent] = [AgentActivityEvent(seq: 0, time: start, kind: .sessionStart)]
        let tools = ["get_window_state", "click", "type_text", "press_key", "click", "scroll", "get_window_state", "set_value", "drag"]
        var seq: UInt64 = 1
        for step in 0..<spec.steps {
            let tool = tools[(step + spec.id.count) % tools.count]
            let app = spec.apps[step % spec.apps.count]
            let isError = step > 0 && spec.errors > 0 && step % max(1, spec.steps / spec.errors) == 0
            let frame = AgentActivityFrameRef(blob: "\(spec.id)|\(app)|\(step)", width: 320, height: 200, expired: step < 2 && spec.minutesAgo > 100)
            let click: CGPoint? = (tool == "click" || tool == "drag")
                ? CGPoint(x: 0.2 + Double((step * 37) % 60) / 100, y: 0.25 + Double((step * 53) % 55) / 100) : nil
            events.append(AgentActivityEvent(
                seq: seq, time: start.addingTimeInterval(Double(step + 1) * 9),
                kind: tool == "get_window_state" ? .observe : .act, tool: tool, target: "\(app) — \(Self.windowTitle(app))",
                ok: !isError, errorCode: isError ? "background_occluded" : nil, durationMs: 40 + (step * 71) % 900,
                redactedTextLength: (tool == "type_text" || tool == "set_value") ? 6 + step % 20 : nil,
                beforeFrame: tool == "get_window_state" ? nil : frame, afterFrame: tool == "press_key" ? nil : frame,
                clickPoint: click))
            seq += 1
        }
        switch spec.status {
        case .paused: events.append(AgentActivityEvent(seq: seq, time: last, kind: .sessionPause))
        case .ended(.userStop): events.append(AgentActivityEvent(seq: seq, time: last, kind: .sessionStop))
        case .ended: events.append(AgentActivityEvent(seq: seq, time: last, kind: .sessionEnd))
        case .active, .idle: break
        }
        return events
    }

    private static func windowTitle(_ app: String) -> String {
        switch app {
        case "Numbers": "Expenses Q3.numbers"
        case "Safari": "Issue 16502 · GitHub"
        case "Figma": "Onboarding v4"
        case "Xcode": "cmux.xcodeproj"
        case "GIMP": "batch-042.png"
        default: app
        }
    }

    /// A stylized window: title bar in the session color, sidebar, rows, and
    /// the step number, so filmstrip frames differ visibly.
    nonisolated static func drawFrame(app: String, step: Int, size: NSSize, tint: String) -> NSImage {
        let color = AgentActivityColor.nsColor(hex: tint)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            color.withAlphaComponent(0.85).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 18).fill()
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: 18, width: rect.width * 0.24, height: rect.height - 18).fill()
            for row in 0..<7 {
                let y = 30 + CGFloat(row) * 22
                let width = rect.width * (0.35 + CGFloat((row * 13 + step * 7) % 40) / 100)
                NSColor(white: row == step % 7 ? 0.55 : 0.8, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.width * 0.3, y: y, width: width, height: 10), xRadius: 3, yRadius: 3).fill()
            }
            let label = "\(app) · \(step + 1)" as NSString
            label.draw(at: NSPoint(x: 6, y: 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            return true
        }
    }
}
