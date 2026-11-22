/// The icon a shell tab draws in its leading slot (cmux.json `tabs.shellIconTheme`; Leo 2026-10-21: "AND WHERE
/// THE F*** ARE THE ICONS FOR THE F***ING MACHINES"). `default` keeps the `>_` kind glyph; `machine` draws the
/// icon of the machine the shell runs on (this Mac's included), so every shell tab says where it runs at a glance.
public nonisolated enum TabShellIconTheme: String, Hashable, Sendable, CaseIterable {
    case `default`
    case machine
}
