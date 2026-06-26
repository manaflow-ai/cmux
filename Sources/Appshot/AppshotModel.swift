import Foundation

/// The result of capturing the frontmost macOS window for an "appshot".
///
/// This is a pure value type (Foundation only) so the message-formatting logic
/// is unit-testable without ScreenCaptureKit / Accessibility / AppKit. The
/// orchestration that produces it lives in ``AppshotController``.
struct AppshotCapture: Equatable {
    /// Localized name of the application that owned the captured window.
    let appName: String
    /// The captured window's title (may be empty when unavailable).
    let windowTitle: String
    /// Absolute file path of the saved PNG screenshot, or `nil` when the image
    /// could not be captured (e.g. Screen Recording permission missing).
    let imagePath: String?
    /// Absolute file path of the saved Accessibility text dump, or `nil` when
    /// no text could be read (e.g. Accessibility permission missing, or the app
    /// exposes no readable text).
    let textPath: String?
    /// Whether the screenshot is absent specifically because Screen Recording
    /// access was not granted (drives the "grant access" hint in the prompt).
    let screenRecordingDenied: Bool
    /// Whether the text dump is absent specifically because Accessibility access
    /// was not granted (drives the "grant access" hint in the prompt).
    let accessibilityDenied: Bool

    /// Builds the single-line message injected into the target agent surface.
    ///
    /// The message references the saved screenshot/text *files by path* rather
    /// than pasting their contents, so it works with every terminal agent
    /// (Claude Code, Codex, …) regardless of whether they accept pasted images
    /// (see https://github.com/manaflow-ai/cmux/issues/6039), and it never
    /// embeds newlines — so appending a single Return submits it cleanly to a
    /// TUI agent instead of executing fragments line-by-line.
    ///
    /// Returns `nil` when neither a screenshot nor any text was captured, so the
    /// caller can surface an error instead of sending an empty prompt.
    func promptText() -> String? {
        let name = Self.singleLine(appName, max: 80)
        let title = Self.singleLine(windowTitle, max: 160)
        let label = title.isEmpty ? name : "\(name) — \(title)"

        switch (imagePath, textPath) {
        case let (image?, text?):
            return String(
                format: String(
                    localized: "appshot.prompt.imageAndText",
                    defaultValue: "[cmux appshot] Captured the frontmost macOS window: %1$@. A screenshot is saved at %2$@ and the window's text (via the Accessibility API) is saved at %3$@. Read both files and use them as context."
                ),
                label, image, text
            )
        case let (image?, nil):
            let hint = accessibilityDenied
                ? String(localized: "appshot.prompt.imageOnly.accessibilityHint", defaultValue: " Grant cmux Accessibility access to also capture the window's text.")
                : ""
            return String(
                format: String(
                    localized: "appshot.prompt.imageOnly",
                    defaultValue: "[cmux appshot] Captured the frontmost macOS window: %1$@. A screenshot is saved at %2$@.%3$@ Read the file and use it as context."
                ),
                label, image, hint
            )
        case let (nil, text?):
            let hint = screenRecordingDenied
                ? String(localized: "appshot.prompt.textOnly.screenRecordingHint", defaultValue: " Grant cmux Screen Recording access to also capture a screenshot.")
                : ""
            return String(
                format: String(
                    localized: "appshot.prompt.textOnly",
                    defaultValue: "[cmux appshot] Captured text from the frontmost macOS window: %1$@. The window's text (via the Accessibility API) is saved at %2$@.%3$@ Read the file and use it as context."
                ),
                label, text, hint
            )
        case (nil, nil):
            return nil
        }
    }

    /// Collapses any whitespace/newlines to single spaces and clamps length, so
    /// titles with embedded newlines can't break the single-line invariant of
    /// ``promptText()``.
    static func singleLine(_ raw: String, max: Int) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > max else { return collapsed }
        return String(collapsed.prefix(max)) + "…"
    }
}

/// Identifies an agent surface (terminal panel) the appshot can be routed to,
/// stamped with the time of the interaction it represents.
struct AppshotAgentRef: Equatable {
    let workspaceId: UUID
    let panelId: UUID
    let at: Date
}

/// Recency state used to decide where an appshot is delivered.
struct AppshotRoutingState: Equatable {
    /// The surface the previous appshot was delivered to. Lets consecutive
    /// appshots stack onto the same thread.
    var lastRoute: AppshotAgentRef?
    /// The agent surface the user most recently interacted with (snapshotted
    /// when cmux resigns active, or resolved live while cmux is frontmost).
    var lastInteractiveAgent: AppshotAgentRef?

    init(lastRoute: AppshotAgentRef? = nil, lastInteractiveAgent: AppshotAgentRef? = nil) {
        self.lastRoute = lastRoute
        self.lastInteractiveAgent = lastInteractiveAgent
    }
}

/// Where an appshot should be delivered.
enum AppshotRoute: Equatable {
    /// Append to (and submit into) an existing agent surface.
    case append(workspaceId: UUID, panelId: UUID)
    /// Start a fresh workspace/thread because no recent agent qualifies.
    case newThread
}

/// Pure resolver implementing the issue's 60-second recency rule.
///
/// - If the previous appshot was delivered within the window and its surface
///   still exists, stack onto it (consecutive appshots stay together).
/// - Otherwise, if the user interacted with an agent within the window and that
///   surface still exists, append to it.
/// - Otherwise start a new thread.
enum AppshotRouteResolver {
    /// Default recency window, in seconds, matching the Codex Appshots behavior.
    static let defaultRecencyWindow: TimeInterval = 60

    /// `lastRouteSurfaceExists` / `lastInteractiveSurfaceExists` are computed by
    /// the caller on the main actor (terminal-panel existence is main-actor
    /// state). Passing them in as plain booleans keeps this resolver pure,
    /// isolation-free, and unit-testable.
    static func resolve(
        now: Date,
        window: TimeInterval = defaultRecencyWindow,
        state: AppshotRoutingState,
        lastRouteSurfaceExists: Bool,
        lastInteractiveSurfaceExists: Bool
    ) -> AppshotRoute {
        if let last = state.lastRoute,
           now.timeIntervalSince(last.at) <= window,
           lastRouteSurfaceExists {
            return .append(workspaceId: last.workspaceId, panelId: last.panelId)
        }
        if let agent = state.lastInteractiveAgent,
           now.timeIntervalSince(agent.at) <= window,
           lastInteractiveSurfaceExists {
            return .append(workspaceId: agent.workspaceId, panelId: agent.panelId)
        }
        return .newThread
    }
}
