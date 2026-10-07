public import CmuxNextDesign
public import CmuxNextDictation
public import CmuxNextSettings
public import Foundation

/// One push from the host to the agent page on the shared page host, an event of the stream
/// ``AgentPageProvider/hostEvents``. Each kind replaces a script the old host evaluated; the
/// page's `hostEvents.ts` runs the same `cmuxAcpmuxBridge` function with `value`.
public nonisolated struct AgentPageEvent: Equatable, Sendable {
    /// `theme`, `shortcuts`, `preview`, `customization`, `registry`, `dictation`, `revealTurn`,
    /// `command`, `focusLocation` or `transport`.
    public let kind: String
    public let value: JSONValue

    public init(kind: String, value: JSONValue = .null) {
        self.kind = kind
        self.value = value
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

    /// A batch of the host socket's frames, or its close (``AgentPaneTransport``, bridgeSocket.ts).
    public static func transport(_ event: AgentPaneTransportEvent) -> AgentPageEvent {
        AgentPageEvent(kind: "transport", value: JSONValue(foundation: event.object) ?? .null)
    }

    /// Focus Location Bar on a new tab page.
    public static let focusLocation = AgentPageEvent(kind: "focusLocation")
}
