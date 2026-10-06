// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SnapshotRequestHave implements WireValue {
    private final Field<UInt64> generation;
    private final Field<UInt64> offset;
    private final Field<Integer> snapshotVersion;

    private SnapshotRequestHave(Builder builder) {
        this.generation = builder.generation;
        this.offset = builder.offset;
        this.snapshotVersion = builder.snapshotVersion;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> generation() { return generation; }
    public Field<UInt64> offset() { return offset; }
    public Field<Integer> snapshotVersion() { return snapshotVersion; }

    public static SnapshotRequestHave fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SnapshotRequestHave");
        Builder builder = builder();
        Object rawGeneration = Wire.optional(object, "generation");
        if (!Wire.isMissing(rawGeneration)) {
            builder.generation(rawGeneration == null ? null : Wire.uint64(rawGeneration, "SnapshotRequestHave.generation"));
        }
        Object rawOffset = Wire.optional(object, "offset");
        if (!Wire.isMissing(rawOffset)) {
            builder.offset(rawOffset == null ? null : Wire.uint64(rawOffset, "SnapshotRequestHave.offset"));
        }
        Object rawSnapshotVersion = Wire.optional(object, "snapshot_version");
        if (!Wire.isMissing(rawSnapshotVersion)) {
            builder.snapshotVersion(rawSnapshotVersion == null ? null : Wire.uint16(rawSnapshotVersion, "SnapshotRequestHave.snapshot_version"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "generation", generation);
        Wire.put(object, "offset", offset);
        Wire.put(object, "snapshot_version", snapshotVersion);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SnapshotRequestHave that)) return false;
        return Objects.equals(generation, that.generation) && Objects.equals(offset, that.offset) && Objects.equals(snapshotVersion, that.snapshotVersion);
    }

    @Override
    public int hashCode() { return Objects.hash(generation, offset, snapshotVersion); }

    @Override
    public String toString() { return "SnapshotRequestHave" + toWire(); }

    public static final class Builder {
        private Field<UInt64> generation = Field.omitted();
        private Field<UInt64> offset = Field.omitted();
        private Field<Integer> snapshotVersion = Field.omitted();

        public Builder generation(UInt64 value) {
            this.generation = Field.ofNullable(value);
            return this;
        }
        public Builder offset(UInt64 value) {
            this.offset = Field.ofNullable(value);
            return this;
        }
        public Builder snapshotVersion(Integer value) {
            this.snapshotVersion = Field.ofNullable(value);
            return this;
        }
        public SnapshotRequestHave build() { return new SnapshotRequestHave(this); }
    }
}
