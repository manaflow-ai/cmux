package com.cmux;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public record Tree(long workspaceRevision, Long paneRevision, List<Workspace> workspaces) {
    public Tree(long workspaceRevision, List<Workspace> workspaces) {
        this(workspaceRevision, null, workspaces);
    }

    public Tree(List<Workspace> workspaces) {
        this(0, null, workspaces);
    }

    @SuppressWarnings("unchecked")
    static Tree from(Map<String, Object> data) {
        List<Workspace> workspaces = new ArrayList<>();
        Object raw = data.get("workspaces");
        if (raw instanceof List<?> list) {
            for (Object item : list) {
                workspaces.add(Workspace.from((Map<String, Object>) item));
            }
        }
        Object revision = data.get("workspace_revision");
        Object paneRevision = data.get("pane_revision");
        return new Tree(
            revision == null ? 0 : CmuxClient.asLong(revision),
            paneRevision == null ? null : CmuxClient.asLong(paneRevision),
            workspaces
        );
    }
}
