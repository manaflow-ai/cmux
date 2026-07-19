package com.cmux;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public record CreateTerminalRequest(
    Long workspace,
    String key,
    List<String> argv,
    String command,
    String cwd,
    String name,
    Integer cols,
    Integer rows
) {
    public CreateTerminalRequest {
        WorkspaceSelectorRequest.requireWorkspaceOrKey(workspace, key);
    }

    Map<String, Object> toMap() {
        Map<String, Object> params = new LinkedHashMap<>();
        if (workspace != null) params.put("workspace", workspace);
        if (key != null) params.put("key", key);
        if (argv != null) params.put("argv", argv);
        if (command != null) params.put("command", command);
        if (cwd != null) params.put("cwd", cwd);
        if (name != null) params.put("name", name);
        if (cols != null) params.put("cols", cols);
        if (rows != null) params.put("rows", rows);
        return params;
    }
}
