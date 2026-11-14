// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsRegistryCleanup implements WireValue {
    private final String error;
    private final ServerStatsRegistryKeptFile keptFile;
    private final UInt64 keptRaw;

    private ServerStatsRegistryCleanup(Builder builder) {
        if (!builder.errorSet) throw new IllegalArgumentException("error is required");
        this.error = builder.error;
        if (!builder.keptFileSet) throw new IllegalArgumentException("kept_file is required");
        this.keptFile = builder.keptFile;
        if (!builder.keptRawSet) throw new IllegalArgumentException("kept_raw is required");
        this.keptRaw = Wire.nonNull(builder.keptRaw, "kept_raw");
    }

    public static Builder builder() { return new Builder(); }

    public String error() { return error; }
    public ServerStatsRegistryKeptFile keptFile() { return keptFile; }
    public UInt64 keptRaw() { return keptRaw; }

    public static ServerStatsRegistryCleanup fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsRegistryCleanup");
        Builder builder = builder();
        Object rawError = Wire.required(object, "error");
        builder.error(rawError == null ? null : Wire.string(rawError, "ServerStatsRegistryCleanup.error"));
        Object rawKeptFile = Wire.required(object, "kept_file");
        builder.keptFile(rawKeptFile == null ? null : ServerStatsRegistryKeptFile.fromWire(rawKeptFile));
        Object rawKeptRaw = Wire.required(object, "kept_raw");
        builder.keptRaw(Wire.uint64(rawKeptRaw, "ServerStatsRegistryCleanup.kept_raw"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "error", error);
        Wire.put(object, "kept_file", keptFile);
        Wire.put(object, "kept_raw", keptRaw);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsRegistryCleanup that)) return false;
        return Objects.equals(error, that.error) && Objects.equals(keptFile, that.keptFile) && Objects.equals(keptRaw, that.keptRaw);
    }

    @Override
    public int hashCode() { return Objects.hash(error, keptFile, keptRaw); }

    @Override
    public String toString() { return "ServerStatsRegistryCleanup" + toWire(); }

    public static final class Builder {
        private String error;
        private boolean errorSet;
        private ServerStatsRegistryKeptFile keptFile;
        private boolean keptFileSet;
        private UInt64 keptRaw;
        private boolean keptRawSet;

        public Builder error(String value) {
            this.error = value;
            this.errorSet = true;
            return this;
        }
        public Builder keptFile(ServerStatsRegistryKeptFile value) {
            this.keptFile = value;
            this.keptFileSet = true;
            return this;
        }
        public Builder keptRaw(UInt64 value) {
            this.keptRaw = value;
            this.keptRawSet = true;
            return this;
        }
        public ServerStatsRegistryCleanup build() { return new ServerStatsRegistryCleanup(this); }
    }
}
