// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalRecord implements WireValue {
    private final TerminalExit exit;
    private final Object launchSpec;
    private final TerminalLifecycle lifecycle;
    private final String terminalId;
    private final String terminalIncarnation;
    private final String workspaceKey;

    private TerminalRecord(Builder builder) {
        if (!builder.exitSet) throw new IllegalArgumentException("exit is required");
        this.exit = builder.exit;
        if (!builder.launchSpecSet) throw new IllegalArgumentException("launch_spec is required");
        this.launchSpec = Wire.immutableJson(Wire.nonNull(builder.launchSpec, "launch_spec"));
        if (!builder.lifecycleSet) throw new IllegalArgumentException("lifecycle is required");
        this.lifecycle = Wire.nonNull(builder.lifecycle, "lifecycle");
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.terminalIncarnationSet) throw new IllegalArgumentException("terminal_incarnation is required");
        this.terminalIncarnation = builder.terminalIncarnation;
        if (!builder.workspaceKeySet) throw new IllegalArgumentException("workspace_key is required");
        this.workspaceKey = Wire.nonNull(builder.workspaceKey, "workspace_key");
    }

    public static Builder builder() { return new Builder(); }

    public TerminalExit exit() { return exit; }
    public Object launchSpec() { return launchSpec; }
    public TerminalLifecycle lifecycle() { return lifecycle; }
    public String terminalId() { return terminalId; }
    public String terminalIncarnation() { return terminalIncarnation; }
    public String workspaceKey() { return workspaceKey; }

    public static TerminalRecord fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalRecord");
        Builder builder = builder();
        Object rawExit = Wire.required(object, "exit");
        builder.exit(rawExit == null ? null : TerminalExit.fromWire(rawExit));
        Object rawLaunchSpec = Wire.required(object, "launch_spec");
        builder.launchSpec(Wire.immutableJson(rawLaunchSpec));
        Object rawLifecycle = Wire.required(object, "lifecycle");
        builder.lifecycle(TerminalLifecycle.fromWire(rawLifecycle));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalRecord.terminal_id"));
        Object rawTerminalIncarnation = Wire.required(object, "terminal_incarnation");
        builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "TerminalRecord.terminal_incarnation"));
        Object rawWorkspaceKey = Wire.required(object, "workspace_key");
        builder.workspaceKey(Wire.string(rawWorkspaceKey, "TerminalRecord.workspace_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "exit", exit);
        Wire.put(object, "launch_spec", launchSpec);
        Wire.put(object, "lifecycle", lifecycle);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "workspace_key", workspaceKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalRecord that)) return false;
        return Objects.equals(exit, that.exit) && Objects.equals(launchSpec, that.launchSpec) && Objects.equals(lifecycle, that.lifecycle) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(workspaceKey, that.workspaceKey);
    }

    @Override
    public int hashCode() { return Objects.hash(exit, launchSpec, lifecycle, terminalId, terminalIncarnation, workspaceKey); }

    @Override
    public String toString() { return "TerminalRecord" + toWire(); }

    public static final class Builder {
        private TerminalExit exit;
        private boolean exitSet;
        private Object launchSpec;
        private boolean launchSpecSet;
        private TerminalLifecycle lifecycle;
        private boolean lifecycleSet;
        private String terminalId;
        private boolean terminalIdSet;
        private String terminalIncarnation;
        private boolean terminalIncarnationSet;
        private String workspaceKey;
        private boolean workspaceKeySet;

        public Builder exit(TerminalExit value) {
            this.exit = value;
            this.exitSet = true;
            return this;
        }
        public Builder launchSpec(Object value) {
            this.launchSpec = value;
            this.launchSpecSet = true;
            return this;
        }
        public Builder lifecycle(TerminalLifecycle value) {
            this.lifecycle = value;
            this.lifecycleSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = value;
            this.terminalIncarnationSet = true;
            return this;
        }
        public Builder workspaceKey(String value) {
            this.workspaceKey = value;
            this.workspaceKeySet = true;
            return this;
        }
        public TerminalRecord build() { return new TerminalRecord(this); }
    }
}
