/// Decides whether a socket control command is *allowed to mutate in-app focus*
/// (steal macOS focus, raise a window, select a workspace) while it executes.
///
/// This is the pure classification half of the focus-preservation policy that
/// previously lived as `static` tables and methods on `TerminalController`
/// (`focusIntentV1Commands`, `focusIntentV2Methods`, `explicitFocusParamV2Methods`,
/// `socketCommandAllowsInAppFocusMutations(commandKey:isV2:params:)`). The
/// runtime allowance *stack* (which window/command is currently executing) is
/// separate live state owned by ``ControlSocketFocusAllowanceStack``; this value
/// only answers "would a command of this shape be permitted to take focus".
///
/// Isolation design: a stateless `Sendable` value of fixed string tables and
/// pure predicates. It takes no `Any` and no app types: the caller extracts the
/// two app-shaped inputs (the v2 `focus` request flag and the v1 `right_sidebar`
/// argument decision) and passes the already-resolved booleans in. That keeps
/// the package free of the legacy `[String: Any]` param bag while the policy
/// itself stays one source of truth for the command tables.
public struct ControlSocketCommandPolicy: Sendable {
    /// Shared default policy carrying the production command tables.
    public static let standard = ControlSocketCommandPolicy()

    public init() {}

    /// True when a v2 method's *intent* is to change focus regardless of any
    /// explicit `focus` param (e.g. `window.focus`, `workspace.select`).
    public func isFocusIntentV2Method(_ method: String) -> Bool {
        Self.focusIntentV2Methods.contains(method)
    }

    /// True when a v1 command's *intent* is to change focus
    /// (e.g. `focus_window`, `activate_app`).
    public func isFocusIntentV1Command(_ command: String) -> Bool {
        Self.focusIntentV1Commands.contains(command)
    }

    /// True when a v2 method honors an explicit per-request `focus` parameter
    /// (e.g. `surface.create`, `pane.join`). The caller resolves the parameter's
    /// boolean value app-side and passes it as `explicitFocusParam`.
    public func honorsExplicitFocusParam(_ method: String) -> Bool {
        Self.explicitFocusParamV2Methods.contains(method)
    }

    /// Whether a command may mutate in-app focus while it runs.
    ///
    /// Mirrors the legacy `socketCommandAllowsInAppFocusMutations(commandKey:isV2:params:)`
    /// decision exactly:
    /// - v2: a focus-intent method, OR an explicit-focus-param method whose
    ///   `focus` param resolved truthy.
    /// - v1 `right_sidebar`: the caller-supplied `rightSidebarAllowsFocus`
    ///   (parsed from the command args app-side).
    /// - other v1: a focus-intent command.
    ///
    /// - Parameters:
    ///   - commandKey: The trimmed command/method name.
    ///   - isV2: Whether this is a v2 (`ControlRequest`) command.
    ///   - explicitFocusParam: For v2, the resolved boolean value of the
    ///     request's `focus` param (false when absent or falsy). Ignored for v1.
    ///   - rightSidebarAllowsFocus: For the v1 `right_sidebar` command, whether
    ///     the parsed request permits focus. Ignored for every other command.
    public func allowsInAppFocusMutations(
        commandKey: String,
        isV2: Bool,
        explicitFocusParam: Bool = false,
        rightSidebarAllowsFocus: Bool = false
    ) -> Bool {
        if isV2 {
            return isFocusIntentV2Method(commandKey)
                || (honorsExplicitFocusParam(commandKey) && explicitFocusParam)
        }
        if commandKey == "right_sidebar" {
            return rightSidebarAllowsFocus
        }
        return isFocusIntentV1Command(commandKey)
    }

    /// v1 commands whose intent is to move focus.
    private static let focusIntentV1Commands: Set<String> = [
        "__internal_flags",
        "focus_window",
        "select_workspace",
        "focus_surface",
        "focus_pane",
        "focus_surface_by_panel",
        "focus_webview",
        "focus_notification",
        "activate_app",
        "debug_right_sidebar_focus",
    ]

    /// v2 methods whose intent is to move focus.
    private static let focusIntentV2Methods: Set<String> = [
        "window.focus",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.group.focus",
        "surface.focus",
        "pane.focus",
        "pane.last",
        "file.open",
        "browser.focus_webview",
        "browser.focus",
        "browser.tab.switch",
        "notification.open",
        "notification.jump_to_unread",
        "debug.command_palette.toggle",
        "debug.notification.focus",
        "debug.app.activate",
        "debug.right_sidebar.focus",
        "feed.jump",
    ]

    /// v2 methods that honor an explicit per-request `focus` parameter.
    private static let explicitFocusParamV2Methods: Set<String> = [
        "workspace.create",
        "layout.open",
        "workspace.move_to_window",
        "surface.split",
        "surface.create",
        "surface.drag_to_split",
        "surface.split_off",
        "surface.move",
        "surface.reorder",
        "surface.action",
        "tab.action",
        "pane.create",
        "pane.swap",
        "pane.break",
        "pane.join",
        "markdown.open",
        "browser.open_split",
        "sidebar.custom.open",
    ]
}
