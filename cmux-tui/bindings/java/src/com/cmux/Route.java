package com.cmux;

import com.cmux.internal.Wire;
import java.util.Map;

/** Known routing/containment selectors carried by a resource handle. */
final class Route {
    final Selector<Ids.MachineId> machine;
    final Selector<Ids.SessionId> session;
    final Selector<Ids.WorkspaceId> workspace;
    final Selector<Ids.ScreenId> screen;
    final Selector<Ids.PaneId> pane;
    final Selector<Ids.TabId> tab;

    private Route(
        Selector<Ids.MachineId> machine,
        Selector<Ids.SessionId> session,
        Selector<Ids.WorkspaceId> workspace,
        Selector<Ids.ScreenId> screen,
        Selector<Ids.PaneId> pane,
        Selector<Ids.TabId> tab
    ) {
        this.machine = machine;
        this.session = session;
        this.workspace = workspace;
        this.screen = screen;
        this.pane = pane;
        this.tab = tab;
    }

    static Route machine(Selector<Ids.MachineId> machine) {
        return new Route(machine, null, null, null, null, null);
    }

    Route session(Selector<Ids.SessionId> value) {
        return new Route(machine, value, null, null, null, null);
    }

    Route workspace(Selector<Ids.WorkspaceId> value) {
        return new Route(machine, session, value, null, null, null);
    }

    Route screen(Selector<Ids.ScreenId> value) {
        return new Route(machine, session, workspace, value, null, null);
    }

    Route pane(Selector<Ids.PaneId> value) {
        return new Route(machine, session, workspace, screen, value, null);
    }

    Route tab(Selector<Ids.TabId> value) {
        return new Route(machine, session, workspace, screen, pane, value);
    }

    Map<String, Object> params() {
        return Client.selectors(
            Wire.MACHINE, machine,
            Wire.SESSION, session,
            Wire.WORKSPACE, workspace,
            Wire.SCREEN, screen,
            Wire.PANE, pane,
            Wire.TAB, tab
        );
    }

    Map<String, Object> target(String name, Object selector) {
        Map<String, Object> result = params();
        result.put(name, selector);
        return result;
    }
}
