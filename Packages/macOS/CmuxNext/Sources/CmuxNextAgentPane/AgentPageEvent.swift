public import CmuxNextDesign
public import CmuxNextDictation
public import CmuxNextSettings
public import Foundation

/// One push from the host to the agent page on the shared page host, an event of the stream
/// ``AgentPageProvider/hostEvents``. Each kind replaces a script the old host evaluated; the
/// page's `hostEvents.ts` runs the same `cmuxAcpmuxBridge` function with `value`.
public nonisolated struct AgentPageEvent: Equatable, Sendable {
    /// `theme`, `shortcuts`, `preview`, `sessionStatus`, `editedFiles`, `customization`, `registry`, `dictation`, `revealTurn`,
    /// `command`, `stopTurn`, `sideQuestion`, `focusLocation` or `transport`.
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

    /// Another app's use of the microphone, for the composer's mark (webviews outsideDictation.ts):
    /// `{active, bundleId?, name?, metered?}`, `metered: true` only while the host meters its level.
    public static func micActivity(_ state: MicrophoneActivity.State) -> AgentPageEvent {
        var value: [String: JSONValue] = ["active": .bool(state.active)]
        if let bundleId = state.bundleId { value["bundleId"] = .string(bundleId) }
        if let name = state.name { value["name"] = .string(name) }
        if state.metered { value["metered"] = .bool(true) }
        return AgentPageEvent(kind: "micActivity", value: .object(value))
    }

    /// The outside dictation's input level while metered: `{level}`, in `0...1` to 3 decimals.
    public static func micLevel(_ level: Float) -> AgentPageEvent {
        let rounded = (Double(min(1, max(0, level))) * 1000).rounded() / 1000
        return AgentPageEvent(kind: "micLevel", value: ["level": .number(rounded.isFinite ? rounded : 0)])
    }

    /// A hand-off from the Toggle Dictation shortcut that did not happen (`{code}`): the composer
    /// shows why, as for the mic's click (webviews dictation.ts).
    public static func dictationHandoff(failure code: String) -> AgentPageEvent {
        AgentPageEvent(kind: "dictationHandoff", value: ["code": .string(code)])
    }

    /// Shows the turn a `#turn-<id>` link names.
    public static func revealTurn(_ turnId: String) -> AgentPageEvent {
        AgentPageEvent(kind: "revealTurn", value: .string(turnId))
    }

    /// A dispatcher command (`searchChats`, `continueIn`, `createCheckpoint`, `permissionAllowOnce`, ...).
    public static func command(_ name: String) -> AgentPageEvent { AgentPageEvent(kind: "command", value: .string(name)) }

    /// A native tab-row control or one of its menu items was invoked.
    public static func tabRowToolInvoked(id: String, menuItemId: String? = nil) -> AgentPageEvent {
        var value: [String: Any] = ["id": id]
        if let menuItemId { value["menuItemId"] = menuItemId }
        return AgentPageEvent(kind: "tabRowToolInvoked", value: JSONValue(foundation: value) ?? .null)
    }

    /// The palette's side-question command, carrying the session selected when it was invoked.
    public static func sideQuestion(_ sessionId: String) -> AgentPageEvent {
        AgentPageEvent(kind: "sideQuestion", value: .string(sessionId))
    }

    /// A batch of the host socket's frames, or its close (``AgentPaneTransport``, bridgeSocket.ts).
    public static func transport(_ event: AgentPaneTransportEvent) -> AgentPageEvent {
        AgentPageEvent(kind: "transport", value: JSONValue(foundation: event.object) ?? .null)
    }

    /// A newly listening port on the Cloud machine running this chat.
    public static func cloudPreviewPort(port: Int, process: String?, machineID: String? = nil,
                                        state: String = "up", known: Bool = false) -> AgentPageEvent {
        var value: [String: Any] = ["port": port]
        if let process, !process.isEmpty { value["process"] = process }
        if let machineID, !machineID.isEmpty { value["machineID"] = machineID }
        value["state"] = state
        value["known"] = known
        return AgentPageEvent(kind: "cloudPreviewPort", value: JSONValue(foundation: value) ?? .null)
    }

    /// The old host's script for a ``cloudPreviewPort(port:process:machineID:state:known:)`` event.
    var cloudPreviewPortScript: String { "window.cmuxAcpmuxCloudPreviewPort?.(\(value.compactText));" }

    /// Focus Location Bar on a new tab page.
    public static let focusLocation = AgentPageEvent(kind: "focusLocation")
}
