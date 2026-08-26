package com.cmux;

/** Closed catalog union for values carried by session resource upserts. */
public sealed interface ResourceEntitySnapshot permits
        Snapshots.MachineSnapshot,
        Snapshots.SessionSnapshot,
        Snapshots.WorkspaceSnapshot,
        Snapshots.ScreenSnapshot,
        Snapshots.PaneSnapshot,
        Snapshots.TabSnapshot,
        Snapshots.TerminalSnapshot,
        Snapshots.BrowserSnapshot,
        Snapshots.ClientSnapshot,
        Snapshots.NotificationSnapshot,
        Snapshots.AgentSnapshot,
        Snapshots.PairingRequestSnapshot,
        Snapshots.FrontendProjectionSnapshot,
        Snapshots.SidebarViewSnapshot {}
