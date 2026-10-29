// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable memory.limit request. Protocol v12; authority: local-admin. */
public final class MemoryLimitRequest implements WireValue {
    private final MemoryPressureLevel level;
    private final MemorySaverMode mode;
    private final Field<MemoryPressureLevel> override;

    private MemoryLimitRequest(Builder builder) {
        if (!builder.levelSet) throw new IllegalArgumentException("level is required");
        this.level = Wire.nonNull(builder.level, "level");
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        this.override = builder.override;
    }

    public static Builder builder() { return new Builder(); }

    public MemoryPressureLevel level() { return level; }
    public MemorySaverMode mode() { return mode; }
    public Field<MemoryPressureLevel> override() { return override; }

    public static MemoryLimitRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MemoryLimitRequest");
        Builder builder = builder();
        Object rawLevel = Wire.required(object, "level");
        builder.level(MemoryPressureLevel.fromWire(rawLevel));
        Object rawMode = Wire.required(object, "mode");
        builder.mode(MemorySaverMode.fromWire(rawMode));
        Object rawOverride = Wire.optional(object, "override");
        if (!Wire.isMissing(rawOverride)) {
            builder.override(rawOverride == null ? null : MemoryPressureLevel.fromWire(rawOverride));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "level", level);
        Wire.put(object, "mode", mode);
        Wire.put(object, "override", override);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MemoryLimitRequest that)) return false;
        return Objects.equals(level, that.level) && Objects.equals(mode, that.mode) && Objects.equals(override, that.override);
    }

    @Override
    public int hashCode() { return Objects.hash(level, mode, override); }

    @Override
    public String toString() { return "MemoryLimitRequest" + toWire(); }

    public static final class Builder {
        private MemoryPressureLevel level;
        private boolean levelSet;
        private MemorySaverMode mode;
        private boolean modeSet;
        private Field<MemoryPressureLevel> override = Field.omitted();

        public Builder level(MemoryPressureLevel value) {
            this.level = value;
            this.levelSet = true;
            return this;
        }
        public Builder mode(MemorySaverMode value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder override(MemoryPressureLevel value) {
            this.override = Field.ofNullable(value);
            return this;
        }
        public MemoryLimitRequest build() { return new MemoryLimitRequest(this); }
    }
}
