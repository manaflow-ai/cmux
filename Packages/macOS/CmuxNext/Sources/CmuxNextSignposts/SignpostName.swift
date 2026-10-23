/// One interval or event name in the cmux signpost catalog.
///
/// Names are `<category>.<what>` and never change meaning: the Debug benches, the Release benches
/// (`scripts/cmux-next/perf-signposts.py`) and PL-telemetry's opt-in hang reports read the same
/// strings. Add a name here, with what its interval spans, before a call site uses it.
///
/// ```swift
/// let state = Signposter.action.begin(.actionPerform, "id=tab.new")
/// ```
public nonisolated struct SignpostName: Sendable, Hashable, CustomStringConvertible {
    /// The name `os_signpost` records (a compile-time string, as the API requires).
    public let staticName: StaticString
    /// The category whose ``Signposter`` emits this name.
    public let category: SignpostCategory

    /// A catalog entry. Only this file declares entries.
    init(_ name: StaticString, _ category: SignpostCategory) {
        staticName = name
        self.category = category
    }

    /// The name as a `String`.
    public var description: String { staticName.withUTF8Buffer { String(decoding: $0, as: UTF8.self) } }

    public static func == (lhs: SignpostName, rhs: SignpostName) -> Bool { lhs.description == rhs.description }
    public func hash(into hasher: inout Hasher) { hasher.combine(description) }

    // MARK: action

    /// From `ActionRegistry` starting an action to its handler returning (the handler's own
    /// main-thread time). Message: `id=<action id> origin=<origin> input_age_ms=<age of the OS event>`.
    public static let actionPerform = SignpostName("action.perform", .action)
    /// From `ActionRegistry` starting an action to the end of the Core Animation commit after it
    /// (``CommitBoundary``): the action's committed frame. Same message as ``actionPerform``;
    /// input to frame is this interval plus `input_age_ms`.
    public static let actionCommit = SignpostName("action.commit", .action)

    // MARK: motion

    /// One layout motion frame: the display-link tick to its presentation applied.
    public static let motionFrame = SignpostName("motion.frame", .motion)
    /// A whole motion: the structural change to the spring at rest.
    public static let motionRun = SignpostName("motion.run", .motion)

    // MARK: key

    /// A key event received by the app to the committed frame that shows its effect.
    public static let keyToFrame = SignpostName("key.frame", .key)

    // MARK: switch

    /// A workspace switch: the intent to the commit that shows the new workspace.
    public static let switchWorkspace = SignpostName("switch.workspace", .switch)
    /// A tab switch: the intent to the commit that shows the tab's content.
    public static let switchTab = SignpostName("switch.tab", .switch)
    /// A pane focus move: the intent to the settled focus.
    public static let switchPaneFocus = SignpostName("switch.pane_focus", .switch)

    // MARK: create

    /// A new tab: the intent to its first themed frame. Message: `kind=<terminal|chromium|webkit|chat|page>`.
    public static let createTab = SignpostName("create.tab", .create)
    /// A new workspace: the intent to its sidebar row drawn.
    public static let createWorkspace = SignpostName("create.workspace", .create)

    // MARK: cef

    /// One Chromium message pump pass on the main thread.
    public static let cefPump = SignpostName("cef.pump", .cef)
    /// `CefBrowserHost::CreateBrowser` on the main thread.
    public static let cefCreateBrowser = SignpostName("cef.create_browser", .cef)
}
