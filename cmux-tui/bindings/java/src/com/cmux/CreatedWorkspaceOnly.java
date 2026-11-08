package com.cmux;

import java.util.Objects;

public record CreatedWorkspaceOnly(Ids.WorkspaceId workspaceId)
        implements CreatedPath {
    public CreatedWorkspaceOnly {
        Objects.requireNonNull(workspaceId, "workspaceId");
    }
}
