package com.cmux;

import java.util.List;
import java.util.Map;
import java.util.Objects;

/** Complete, atomic session snapshot returned by {@code session.snapshot}. */
public record ResourceSnapshot(
    Snapshots.MachineSnapshot machine,
    Snapshots.SessionSnapshot session,
    List<Snapshots.WorkspaceSnapshot> workspaces,
    List<Snapshots.ScreenSnapshot> screens,
    List<Snapshots.PaneSnapshot> panes,
    List<Snapshots.TabSnapshot> tabs,
    List<Snapshots.TerminalSnapshot> terminals,
    List<Snapshots.BrowserSnapshot> browsers,
    List<Snapshots.ClientSnapshot> clients,
    List<Snapshots.NotificationSnapshot> notifications,
    List<Snapshots.AgentSnapshot> agents,
    List<Snapshots.FrontendProjectionSnapshot> frontendProjections,
    List<Snapshots.SidebarViewSnapshot> sidebarViews,
    Cursor cursor,
    Map<String, Object> extra
) {
    public ResourceSnapshot {
        Objects.requireNonNull(machine, "machine");
        Objects.requireNonNull(session, "session");
        workspaces = List.copyOf(workspaces);
        screens = List.copyOf(screens);
        panes = List.copyOf(panes);
        tabs = List.copyOf(tabs);
        terminals = List.copyOf(terminals);
        browsers = List.copyOf(browsers);
        clients = List.copyOf(clients);
        notifications = List.copyOf(notifications);
        agents = List.copyOf(agents);
        frontendProjections = List.copyOf(frontendProjections);
        sidebarViews = List.copyOf(sidebarViews);
        Objects.requireNonNull(cursor, "cursor");
        extra = extra == null
            ? Map.of()
            : JsonValue.immutableObject(extra, "resource snapshot extra");
    }
}
