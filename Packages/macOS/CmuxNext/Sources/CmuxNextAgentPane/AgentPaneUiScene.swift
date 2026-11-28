#if DEBUG
public import AppKit

/// DEBUG ONLY: the UI shell's AgentPane scene (Prototypes/UiLayerHost `cmux-ui-agentpane --shoot DIR --scene
/// agentpane-native`, goal auto-ui-preview-under-60s): the pane's native AppKit parts with fixture data, the
/// Session Info panel (subagents, a waiting ask, a failed check) and the Computer use act-as-me card, each in a
/// window of its own. The chat itself is a web page (the web gallery draws it); a push to CmuxNextAgentPane gets
/// its before and after of the native parts from these, built without the app.
@MainActor
public struct AgentPaneUiScene {
    public init() {}
    static let info: [String: Any] = [
        "open": true, "width": 320.0, "top": 28.0, "side": 0.0, "label": "Session Info",
        "sections": [
            [
                "id": "subagents", "group": "running", "title": "Subagents", "meta": "2 running",
                "open": true, "foldable": true,
                "rows": [
                    ["id": "a1", "title": "rail-fix", "tone": "running", "action": "subagents.open:a1",
                     "buttons": [["label": "Stop", "action": "subagents.stop:a1"]]],
                    ["id": "a2", "title": "docs pass", "tone": "running", "action": "subagents.open:a2"],
                    ["id": "a3", "title": "bench rerun", "tone": "done", "action": "subagents.open:a3"],
                ],
            ],
            [
                "id": "asks", "group": "waiting", "title": "Waiting on you", "meta": "1",
                "open": true, "foldable": true,
                "rows": [["id": "q1", "title": "Allow edits to Package.swift?", "tone": "waiting",
                          "action": "asks.open:q1"]],
            ],
            [
                "id": "checks", "group": "failed", "title": "Checks", "meta": "1 failed",
                "open": true, "foldable": true,
                "rows": [["id": "c1", "title": "swift test CmuxNextAgentPane", "tone": "failed",
                          "action": "checks.open:c1"]],
            ],
        ],
    ]

    /// Opens the scene's windows (each a new window: the shooter draws every window a scene opens) and returns what
    /// the caller keeps alive for the shot.
    public static func show() -> [AnyObject] {
        var held: [AnyObject] = []
        let store = AgentPaneSessionInfoStore()
        let panel = AgentPaneSessionInfoPanel(store: store)
        store.update(AgentPaneSessionInfoModel.decode(info))
        let height = max(160, min(560, panel.fittingHeight(forWidth: 320)))
        held.append(open(panel, title: "Session Info", size: NSSize(width: 320, height: height)))
        held.append(store)

        let card = AgentPaneActAsMeCardView(grant: AgentPaneActAsMe(store: .memory()))
        held.append(open(card, title: "Act as me", size: card.frame.size))
        return held
    }

    private static func open(_ view: NSView, title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "AgentPane: \(title)"
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        return window
    }
}
#endif
