// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRegistryKeptFile implements WireValue {
    private final UInt64 bytes;
    private final UInt64 fullStarts;
    private final UInt64 fullStartsLeft;
    private final UInt64 keptUntilMs;
    private final String name;
    private final UInt64 swappedAtMs;

    private ServerStatsRegistryKeptFile(Builder builder) {
        if (!builder.bytesSet) throw new IllegalArgumentException("bytes is required");
        this.bytes = Wire.nonNull(builder.bytes, "bytes");
        if (!builder.fullStartsSet) throw new IllegalArgumentException("full_starts is required");
        this.fullStarts = Wire.nonNull(builder.fullStarts, "full_starts");
        if (!builder.fullStartsLeftSet) throw new IllegalArgumentException("full_starts_left is required");
        this.fullStartsLeft = Wire.nonNull(builder.fullStartsLeft, "full_starts_left");
        if (!builder.keptUntilMsSet) throw new IllegalArgumentException("kept_until_ms is required");
        this.keptUntilMs = builder.keptUntilMs;
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.swappedAtMsSet) throw new IllegalArgumentException("swapped_at_ms is required");
        this.swappedAtMs = builder.swappedAtMs;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 bytes() { return bytes; }
    public UInt64 fullStarts() { return fullStarts; }
    public UInt64 fullStartsLeft() { return fullStartsLeft; }
    public UInt64 keptUntilMs() { return keptUntilMs; }
    public String name() { return name; }
    public UInt64 swappedAtMs() { return swappedAtMs; }

    public static ServerStatsRegistryKeptFile fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRegistryKeptFile");
        Builder builder = builder();
        Object rawBytes = Wire.required(object, "bytes");
        builder.bytes(Wire.uint64(rawBytes, "ServerStatsRegistryKeptFile.bytes"));
        Object rawFullStarts = Wire.required(object, "full_starts");
        builder.fullStarts(Wire.uint64(rawFullStarts, "ServerStatsRegistryKeptFile.full_starts"));
        Object rawFullStartsLeft = Wire.required(object, "full_starts_left");
        builder.fullStartsLeft(Wire.uint64(rawFullStartsLeft, "ServerStatsRegistryKeptFile.full_starts_left"));
        Object rawKeptUntilMs = Wire.required(object, "kept_until_ms");
        builder.keptUntilMs(rawKeptUntilMs == null ? null : Wire.uint64(rawKeptUntilMs, "ServerStatsRegistryKeptFile.kept_until_ms"));
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "ServerStatsRegistryKeptFile.name"));
        Object rawSwappedAtMs = Wire.required(object, "swapped_at_ms");
        builder.swappedAtMs(rawSwappedAtMs == null ? null : Wire.uint64(rawSwappedAtMs, "ServerStatsRegistryKeptFile.swapped_at_ms"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "bytes", bytes);
        Wire.put(object, "full_starts", fullStarts);
        Wire.put(object, "full_starts_left", fullStartsLeft);
        Wire.put(object, "kept_until_ms", keptUntilMs);
        Wire.put(object, "name", name);
        Wire.put(object, "swapped_at_ms", swappedAtMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRegistryKeptFile that)) return false;
        return Objects.equals(bytes, that.bytes) && Objects.equals(fullStarts, that.fullStarts) && Objects.equals(fullStartsLeft, that.fullStartsLeft) && Objects.equals(keptUntilMs, that.keptUntilMs) && Objects.equals(name, that.name) && Objects.equals(swappedAtMs, that.swappedAtMs);
    }

    @Override
    public int hashCode() { return Objects.hash(bytes, fullStarts, fullStartsLeft, keptUntilMs, name, swappedAtMs); }

    @Override
    public String toString() { return "ServerStatsRegistryKeptFile" + toWire(); }

    public static final class Builder {
        private UInt64 bytes;
        private boolean bytesSet;
        private UInt64 fullStarts;
        private boolean fullStartsSet;
        private UInt64 fullStartsLeft;
        private boolean fullStartsLeftSet;
        private UInt64 keptUntilMs;
        private boolean keptUntilMsSet;
        private String name;
        private boolean nameSet;
        private UInt64 swappedAtMs;
        private boolean swappedAtMsSet;

        public Builder bytes(UInt64 value) {
            this.bytes = value;
            this.bytesSet = true;
            return this;
        }
        public Builder fullStarts(UInt64 value) {
            this.fullStarts = value;
            this.fullStartsSet = true;
            return this;
        }
        public Builder fullStartsLeft(UInt64 value) {
            this.fullStartsLeft = value;
            this.fullStartsLeftSet = true;
            return this;
        }
        public Builder keptUntilMs(UInt64 value) {
            this.keptUntilMs = value;
            this.keptUntilMsSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder swappedAtMs(UInt64 value) {
            this.swappedAtMs = value;
            this.swappedAtMsSet = true;
            return this;
        }
        public ServerStatsRegistryKeptFile build() { return new ServerStatsRegistryKeptFile(this); }
    }
}
