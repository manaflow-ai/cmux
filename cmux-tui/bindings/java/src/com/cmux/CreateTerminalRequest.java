package com.cmux;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class CreateTerminalRequest {
    private final Long workspace;
    private final String key;
    private final List<String> argv;
    private final String command;
    private final String cwd;
    private final String name;
    private final Integer cols;
    private final Integer rows;

    private CreateTerminalRequest(Builder builder) {
        this.workspace = builder.workspace;
        this.key = builder.key;
        this.argv = builder.argv == null ? null : List.copyOf(builder.argv);
        this.command = builder.command;
        this.cwd = builder.cwd;
        this.name = builder.name;
        this.cols = builder.cols;
        this.rows = builder.rows;
    }

    public static Builder builder() {
        return new Builder();
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

    public static final class Builder {
        private Long workspace;
        private String key;
        private List<String> argv;
        private String command;
        private String cwd;
        private String name;
        private Integer cols;
        private Integer rows;

        public Builder workspace(long workspace) { this.workspace = workspace; return this; }
        public Builder key(String key) { this.key = key; return this; }
        public Builder argv(List<String> argv) { this.argv = argv; return this; }
        public Builder command(String command) { this.command = command; return this; }
        public Builder cwd(String cwd) { this.cwd = cwd; return this; }
        public Builder name(String name) { this.name = name; return this; }
        public Builder cols(int cols) { this.cols = cols; return this; }
        public Builder rows(int rows) { this.rows = rows; return this; }

        public CreateTerminalRequest build() {
            WorkspaceSelectorRequest.requireWorkspaceOrKey(workspace, key);
            return new CreateTerminalRequest(this);
        }
    }
}
