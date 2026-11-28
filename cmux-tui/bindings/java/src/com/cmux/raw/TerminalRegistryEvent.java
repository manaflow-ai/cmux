// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalRegistryEvent implements WireValue {
    private final String kind;
    private final String mutationId;
    private final String origin;
    private final Object result;
    private final String terminalId;
    private final UInt64 terminalRevision;
    private final String workspaceKey;

    private TerminalRegistryEvent(Builder builder) {
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.mutationIdSet) throw new IllegalArgumentException("mutation_id is required");
        this.mutationId = Wire.nonNull(builder.mutationId, "mutation_id");
        if (!builder.originSet) throw new IllegalArgumentException("origin is required");
        this.origin = Wire.nonNull(builder.origin, "origin");
        if (!builder.resultSet) throw new IllegalArgumentException("result is required");
        this.result = Wire.immutableJson(Wire.nonNull(builder.result, "result"));
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        if (!builder.terminalRevisionSet) throw new IllegalArgumentException("terminal_revision is required");
        this.terminalRevision = Wire.nonNull(builder.terminalRevision, "terminal_revision");
        if (!builder.workspaceKeySet) throw new IllegalArgumentException("workspace_key is required");
        this.workspaceKey = Wire.nonNull(builder.workspaceKey, "workspace_key");
    }

    public static Builder builder() { return new Builder(); }

    public String kind() { return kind; }
    public String mutationId() { return mutationId; }
    public String origin() { return origin; }
    public Object result() { return result; }
    public String terminalId() { return terminalId; }
    public UInt64 terminalRevision() { return terminalRevision; }
    public String workspaceKey() { return workspaceKey; }

    public static TerminalRegistryEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalRegistryEvent");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "TerminalRegistryEvent.kind"));
        Object rawMutationId = Wire.required(object, "mutation_id");
        builder.mutationId(Wire.string(rawMutationId, "TerminalRegistryEvent.mutation_id"));
        Object rawOrigin = Wire.required(object, "origin");
        builder.origin(Wire.string(rawOrigin, "TerminalRegistryEvent.origin"));
        Object rawResult = Wire.required(object, "result");
        builder.result(Wire.immutableJson(rawResult));
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "TerminalRegistryEvent.terminal_id"));
        Object rawTerminalRevision = Wire.required(object, "terminal_revision");
        builder.terminalRevision(Wire.uint64(rawTerminalRevision, "TerminalRegistryEvent.terminal_revision"));
        Object rawWorkspaceKey = Wire.required(object, "workspace_key");
        builder.workspaceKey(Wire.string(rawWorkspaceKey, "TerminalRegistryEvent.workspace_key"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "result", result);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_revision", terminalRevision);
        Wire.put(object, "workspace_key", workspaceKey);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalRegistryEvent that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(result, that.result) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalRevision, that.terminalRevision) && Objects.equals(workspaceKey, that.workspaceKey);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, mutationId, origin, result, terminalId, terminalRevision, workspaceKey); }

    @Override
    public String toString() { return "TerminalRegistryEvent" + toWire(); }

    public static final class Builder {
        private String kind;
        private boolean kindSet;
        private String mutationId;
        private boolean mutationIdSet;
        private String origin;
        private boolean originSet;
        private Object result;
        private boolean resultSet;
        private String terminalId;
        private boolean terminalIdSet;
        private UInt64 terminalRevision;
        private boolean terminalRevisionSet;
        private String workspaceKey;
        private boolean workspaceKeySet;

        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = value;
            this.mutationIdSet = true;
            return this;
        }
        public Builder origin(String value) {
            this.origin = value;
            this.originSet = true;
            return this;
        }
        public Builder result(Object value) {
            this.result = value;
            this.resultSet = true;
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder terminalRevision(UInt64 value) {
            this.terminalRevision = value;
            this.terminalRevisionSet = true;
            return this;
        }
        public Builder workspaceKey(String value) {
            this.workspaceKey = value;
            this.workspaceKeySet = true;
            return this;
        }
        public TerminalRegistryEvent build() { return new TerminalRegistryEvent(this); }
    }
}
