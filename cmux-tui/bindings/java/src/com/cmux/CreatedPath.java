package com.cmux;

import java.util.Optional;

public record CreatedPath(
    Optional<Ids.MachineId> machine,
    Optional<Ids.SessionId> session,
    Optional<Ids.WorkspaceId> workspace,
    Optional<Ids.ScreenId> screen,
    Optional<Ids.PaneId> pane,
    Optional<Ids.TabId> tab,
    Optional<Ids.TerminalId> terminal,
    Optional<Ids.BrowserId> browser
) {
    public CreatedPath {
        machine = optional(machine);
        session = optional(session);
        workspace = optional(workspace);
        screen = optional(screen);
        pane = optional(pane);
        tab = optional(tab);
        terminal = optional(terminal);
        browser = optional(browser);
    }

    private static <T> Optional<T> optional(Optional<T> value) {
        return value == null ? Optional.empty() : value;
    }
}
