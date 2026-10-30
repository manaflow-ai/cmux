// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalCommandList implements WireValue {
    private final List<TerminalCommandRecord> commands;
    private final String deletions;
    private final String registryId;
    private final long retentionDays;
    private final boolean truncated;

    private TerminalCommandList(Builder builder) {
        if (!builder.commandsSet) throw new IllegalArgumentException("commands is required");
        this.commands = List.copyOf(Wire.nonNull(builder.commands, "commands"));
        if (!builder.deletionsSet) throw new IllegalArgumentException("deletions is required");
        this.deletions = Wire.nonNull(builder.deletions, "deletions");
        if (!builder.registryIdSet) throw new IllegalArgumentException("registry_id is required");
        this.registryId = Wire.nonNull(builder.registryId, "registry_id");
        if (!builder.retentionDaysSet) throw new IllegalArgumentException("retention_days is required");
        this.retentionDays = builder.retentionDays;
        if (!builder.truncatedSet) throw new IllegalArgumentException("truncated is required");
        this.truncated = builder.truncated;
    }

    public static Builder builder() { return new Builder(); }

    public List<TerminalCommandRecord> commands() { return commands; }
    public String deletions() { return deletions; }
    public String registryId() { return registryId; }
    public long retentionDays() { return retentionDays; }
    public boolean truncated() { return truncated; }

    public static TerminalCommandList fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalCommandList");
        Builder builder = builder();
        Object rawCommands = Wire.required(object, "commands");
        builder.commands(Wire.array(rawCommands, "TerminalCommandList.commands", item -> TerminalCommandRecord.fromWire(item)));
        Object rawDeletions = Wire.required(object, "deletions");
        builder.deletions(Wire.string(rawDeletions, "TerminalCommandList.deletions"));
        Object rawRegistryId = Wire.required(object, "registry_id");
        builder.registryId(Wire.string(rawRegistryId, "TerminalCommandList.registry_id"));
        Object rawRetentionDays = Wire.required(object, "retention_days");
        builder.retentionDays(Wire.uint32(rawRetentionDays, "TerminalCommandList.retention_days"));
        Object rawTruncated = Wire.required(object, "truncated");
        builder.truncated(Wire.bool(rawTruncated, "TerminalCommandList.truncated"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "commands", commands);
        Wire.put(object, "deletions", deletions);
        Wire.put(object, "registry_id", registryId);
        Wire.put(object, "retention_days", retentionDays);
        Wire.put(object, "truncated", truncated);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalCommandList that)) return false;
        return Objects.equals(commands, that.commands) && Objects.equals(deletions, that.deletions) && Objects.equals(registryId, that.registryId) && Objects.equals(retentionDays, that.retentionDays) && Objects.equals(truncated, that.truncated);
    }

    @Override
    public int hashCode() { return Objects.hash(commands, deletions, registryId, retentionDays, truncated); }

    @Override
    public String toString() { return "TerminalCommandList" + toWire(); }

    public static final class Builder {
        private List<TerminalCommandRecord> commands;
        private boolean commandsSet;
        private String deletions;
        private boolean deletionsSet;
        private String registryId;
        private boolean registryIdSet;
        private Long retentionDays;
        private boolean retentionDaysSet;
        private Boolean truncated;
        private boolean truncatedSet;

        public Builder commands(List<TerminalCommandRecord> value) {
            this.commands = value;
            this.commandsSet = true;
            return this;
        }
        public Builder deletions(String value) {
            this.deletions = value;
            this.deletionsSet = true;
            return this;
        }
        public Builder registryId(String value) {
            this.registryId = value;
            this.registryIdSet = true;
            return this;
        }
        public Builder retentionDays(long value) {
            this.retentionDays = value;
            this.retentionDaysSet = true;
            return this;
        }
        public Builder truncated(boolean value) {
            this.truncated = value;
            this.truncatedSet = true;
            return this;
        }
        public TerminalCommandList build() { return new TerminalCommandList(this); }
    }
}
