package com.cmux;

import java.util.Objects;
import java.util.Optional;

public record CreatedBrowserPath(
    Ids.WorkspaceId workspaceId,
    Ids.ScreenId screenId,
    Ids.PaneId paneId,
    Ids.TabId tabId,
    Ids.BrowserId browserId
) implements CreatedPath {
    public CreatedBrowserPath {
        Objects.requireNonNull(workspaceId, "workspaceId");
        Objects.requireNonNull(screenId, "screenId");
        Objects.requireNonNull(paneId, "paneId");
        Objects.requireNonNull(tabId, "tabId");
        Objects.requireNonNull(browserId, "browserId");
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
    public Optional<Ids.BrowserId> browser() {
        return Optional.of(browserId);
    }
}
