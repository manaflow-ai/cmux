/// `tabs.commandDigits` in cmux.json: what Cmd-1…9 select. `workspaces` (the
/// default) keeps the sidebar on Cmd-1…9 and the focused pane's tabs on
/// Ctrl-1…9. `tabs` trades the two: Cmd-1…9 select tabs (Cmd-9 the last) and
/// Ctrl-1…9 workspaces. A binding the user set for either action wins, and then
/// neither moves (`SettingsApplier`), as with `tabs.swapCmdTAndCmdN`.
public nonisolated enum CommandDigitsSetting: String, CaseIterable, Sendable {
    case workspaces
    case tabs

    // `configPath` and `fallback` are generated from schemas/settings/source/sidebar.json.
}
