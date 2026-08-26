package com.cmux;

import java.util.Optional;

/** Closed catalog union for workspace, terminal, and browser creation paths. */
public sealed interface CreatedPath permits
        CreatedWorkspaceOnly,
        CreatedTerminalPath,
        CreatedBrowserPath {
    Ids.WorkspaceId workspaceId();

    default Optional<Ids.ScreenId> screen() {
        return Optional.empty();
    }

    default Optional<Ids.PaneId> pane() {
        return Optional.empty();
    }

    default Optional<Ids.TabId> tab() {
        return Optional.empty();
    }

    default Optional<Ids.TerminalId> terminal() {
        return Optional.empty();
    }

    default Optional<Ids.BrowserId> browser() {
        return Optional.empty();
    }
}
