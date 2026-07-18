package com.cmux;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

public final class EnsureTerminalRequest {
    private final UUID workspaceUuid;
    private final UUID surfaceUuid;
    private final int cols;
    private final int rows;
    private final String cwd;
    private final List<String> argv;
    private final String command;
    private final List<EnsureTerminalEnvironment> environment;
    private final String initialInput;
    private final boolean waitAfterCommand;

    private EnsureTerminalRequest(Builder builder) {
        workspaceUuid = Objects.requireNonNull(builder.workspaceUuid, "workspaceUuid");
        surfaceUuid = Objects.requireNonNull(builder.surfaceUuid, "surfaceUuid");
        if (builder.cols < 1 || builder.cols > 65535 || builder.rows < 1 || builder.rows > 65535) {
            throw new IllegalArgumentException("ensure-terminal dimensions must be in 1...65535");
        }
        if (builder.argv != null && builder.command != null) {
            throw new IllegalArgumentException("ensure-terminal argv and command are mutually exclusive");
        }
        if (builder.argv != null && builder.argv.isEmpty()) {
            throw new IllegalArgumentException("ensure-terminal argv must be non-empty when supplied");
        }
        cols = builder.cols;
        rows = builder.rows;
        cwd = builder.cwd;
        argv = builder.argv == null ? null : List.copyOf(builder.argv);
        command = builder.command;
        environment = List.copyOf(builder.environment);
        initialInput = builder.initialInput;
        waitAfterCommand = builder.waitAfterCommand;
    }

    public static Builder builder(UUID workspaceUuid, UUID surfaceUuid, int cols, int rows) {
        return new Builder(workspaceUuid, surfaceUuid, cols, rows);
    }

    Map<String, Object> toMap() {
        Map<String, Object> map = new LinkedHashMap<>();
        map.put("workspace_uuid", workspaceUuid.toString());
        map.put("surface_uuid", surfaceUuid.toString());
        map.put("cols", cols);
        map.put("rows", rows);
        if (cwd != null) map.put("cwd", cwd);
        if (argv != null) map.put("argv", argv);
        if (command != null) map.put("command", command);
        if (!environment.isEmpty()) {
            map.put("env", environment.stream().map(EnsureTerminalEnvironment::toMap).toList());
        }
        if (initialInput != null) map.put("initial_input", initialInput);
        map.put("wait_after_command", waitAfterCommand);
        return map;
    }

    public static final class Builder {
        private final UUID workspaceUuid;
        private final UUID surfaceUuid;
        private final int cols;
        private final int rows;
        private String cwd;
        private List<String> argv;
        private String command;
        private List<EnsureTerminalEnvironment> environment = List.of();
        private String initialInput;
        private boolean waitAfterCommand;

        private Builder(UUID workspaceUuid, UUID surfaceUuid, int cols, int rows) {
            this.workspaceUuid = workspaceUuid;
            this.surfaceUuid = surfaceUuid;
            this.cols = cols;
            this.rows = rows;
        }

        public Builder cwd(String cwd) { this.cwd = cwd; return this; }
        public Builder argv(List<String> argv) { this.argv = argv; return this; }
        public Builder command(String command) { this.command = command; return this; }
        public Builder environment(List<EnsureTerminalEnvironment> environment) {
            this.environment = Objects.requireNonNull(environment, "environment");
            return this;
        }
        public Builder initialInput(String initialInput) { this.initialInput = initialInput; return this; }
        public Builder waitAfterCommand(boolean waitAfterCommand) {
            this.waitAfterCommand = waitAfterCommand;
            return this;
        }
        public EnsureTerminalRequest build() { return new EnsureTerminalRequest(this); }
    }
}
