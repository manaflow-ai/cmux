package com.cmux;

import java.util.Objects;
import java.util.Optional;

public record CreatedTerminalPath(
    Ids.WorkspaceId workspaceId,
    Ids.ScreenId screenId,
    Ids.PaneId paneId,
    Ids.TabId tabId,
    Ids.TerminalId terminalId
) implements CreatedPath {
    public CreatedTerminalPath {
        Objects.requireNonNull(workspaceId, "workspaceId");
        Objects.requireNonNull(screenId, "screenId");
        Objects.requireNonNull(paneId, "paneId");
        Objects.requireNonNull(tabId, "tabId");
        Objects.requireNonNull(terminalId, "terminalId");
    }

    @Override
    public Optional<Ids.ScreenId> screen() {
        return Optional.of(screenId);
    }

    @Override
    public Optional<Ids.PaneId> pane() {
        return Optional.of(paneId);
    }

    @Override
    public Optional<Ids.TabId> tab() {
        return Optional.of(tabId);
    }

    @Override
    public Optional<Ids.TerminalId> terminal() {
        return Optional.of(terminalId);
    }
}
