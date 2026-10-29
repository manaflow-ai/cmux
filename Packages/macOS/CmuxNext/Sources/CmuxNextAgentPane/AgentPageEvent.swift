public import CmuxNextDesign
public import CmuxNextDictation
public import CmuxNextSettings
public import Foundation

/// One push from the host to the agent page on the shared page host, an event of the stream
/// ``AgentPageProvider/hostEvents``. Each kind replaces a script the old host evaluated; the
/// page's `hostEvents.ts` runs the same `cmuxAcpmuxBridge` function with `value`.
public nonisolated struct AgentPageEvent: Equatable, Sendable {
    /// `theme`, `shortcuts`, `preview`, `sessionStatus`, `editedFiles`, `customization`, `registry`, `dictation`, `revealTurn`,
    /// `command`, `stopTurn`, `focusLocation` or `transport`.
    public let kind: String
    public let value: JSONValue
    let deliveryID: UInt64?

    public init(kind: String, value: JSONValue = .null, deliveryID: UInt64? = nil) {
        self.kind = kind
        self.value = value
        self.deliveryID = deliveryID
    }

    /// The stream event: `{kind, value}`.
    public var data: JSONValue { ["kind": .string(kind), "value": value] }

    /// The shared web theme for `surface` (`web`, `--cmux-*`) and the pane's own values (`agent`).
    @MainActor public static func theme(_ tokens: ThemeTokens, surface: SurfaceKind) -> AgentPageEvent? {
        guard let web = try? JSONValue.parse(Data(AgentPaneTheme.webTheme(tokens, surface: surface).payloadJSON.utf8)),
              let agent = JSONValue(foundation: AgentPaneTheme.values(tokens, surface: surface)) else { return nil }
        return AgentPageEvent(kind: "theme", value: ["web": web, "agent": agent])
    }

    /// The shortcut labels the page shows.
    public static func shortcuts(_ shortcuts: AgentPaneShortcuts) -> AgentPageEvent {
        AgentPageEvent(kind: "shortcuts", value: .object(shortcuts.labels.mapValues(JSONValue.string)))
    }

    /// Whether preview features show.
    public static func preview(_ on: Bool) -> AgentPageEvent { AgentPageEvent(kind: "preview", value: .bool(on)) }
    /// Whether agents suggest tasks (``AgentPaneSuggestedTasks``, cx-lo9yf).
    public static func suggestedTasks(_ on: Bool) -> AgentPageEvent { AgentPageEvent(kind: "suggestedTasks", value: .bool(on)) }

    /// Whether the in-session status cards show (the `agent.sessionStatus` tunable).
    public static func sessionStatus(_ on: Bool) -> AgentPageEvent { AgentPageEvent(kind: "sessionStatus", value: .bool(on)) }

    /// `{themeCSS, layout}`. A missing theme sends `""`, which clears the style a deleted `theme.css`
    /// left; a bad layout sends `{}`. The user's `registry.js` is not an event: the view evaluates it
    /// (``AgentPaneCustomization/registryScript``), since the page's CSP refuses a script the page
    /// makes itself.
    public static func customization(_ customization: AgentPaneCustomization) -> [AgentPageEvent] {
        var events: [AgentPageEvent] = []
        var layout = JSONValue.object([:])
        if let text = customization.layoutJSON, let parsed = try? JSONValue.parse(Data(text.utf8)), case .object = parsed {
            layout = parsed
        }
        events.append(AgentPageEvent(kind: "customization", value: [
            "themeCSS": .string(customization.themeCSS ?? ""), "layout": layout,
        ]))
        return events
    }

    /// A dictation update for the composer.
    @MainActor public static func dictation(_ update: DictationUpdate) -> AgentPageEvent? {
        JSONValue(foundation: AgentPaneDictation.payload(update)).map { AgentPageEvent(kind: "dictation", value: $0) }
    }

    /// Shows the turn a `#turn-<id>` link names.
    public static func revealTurn(_ turnId: String) -> AgentPageEvent {
        AgentPageEvent(kind: "revealTurn", value: .string(turnId))
    }

    /// A dispatcher command (`searchChats`, `continueIn`, `createCheckpoint`, `permissionAllowOnce`, ...).
    public static func command(_ name: String) -> AgentPageEvent { AgentPageEvent(kind: "command", value: .string(name)) }

    /// The current declarative native tab-row controls.
    public static func tabRowTools(_ tools: [PaneTabRowTool]) -> AgentPageEvent {
        let value = tools.map { tool in
            var object: [String: Any] = ["id": tool.id, "symbol": tool.symbol, "label": tool.label,
                                         "enabled": tool.enabled, "toggled": tool.toggled]
            if let badge = tool.badge { object["badge"] = badge }
            if !tool.menu.isEmpty { object["menu"] = tool.menu.map(menuObject) }
            return object
        }
        return AgentPageEvent(kind: "tabRowTools", value: JSONValue(foundation: value) ?? .array([]))
    }

    /// A native tab-row control or one of its menu items was invoked.
    public static func tabRowToolInvoked(id: String, menuItemId: String? = nil) -> AgentPageEvent {
        var value: [String: Any] = ["id": id]
        if let menuItemId { value["menuItemId"] = menuItemId }
        return AgentPageEvent(kind: "tabRowToolInvoked", value: JSONValue(foundation: value) ?? .null)
    }

    private static func menuObject(_ item: PaneTabRowMenuItem) -> [String: Any] {
        var object: [String: Any] = ["id": item.id, "label": item.label, "enabled": item.enabled]
        if let checked = item.checked { object["checked"] = checked }
        if let role = item.role { object["role"] = role }
        if !item.children.isEmpty { object["children"] = item.children.map(menuObject) }
        return object
    }

    /// A batch of the host socket's frames, or its close (``AgentPaneTransport``, bridgeSocket.ts).
    public static func transport(_ event: AgentPaneTransportEvent) -> AgentPageEvent {
        AgentPageEvent(kind: "transport", value: JSONValue(foundation: event.object) ?? .null)
    }

    /// Focus Location Bar on a new tab page.
    public static let focusLocation = AgentPageEvent(kind: "focusLocation")
}
