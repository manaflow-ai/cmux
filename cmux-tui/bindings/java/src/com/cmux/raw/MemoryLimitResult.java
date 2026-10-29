// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MemoryLimitResult implements WireValue {
    private final boolean changed;
    private final MemoryPressureLevel level;

    private MemoryLimitResult(Builder builder) {
        if (!builder.changedSet) throw new IllegalArgumentException("changed is required");
        this.changed = builder.changed;
        if (!builder.levelSet) throw new IllegalArgumentException("level is required");
        this.level = Wire.nonNull(builder.level, "level");
    }

    public static Builder builder() { return new Builder(); }

    public boolean changed() { return changed; }
    public MemoryPressureLevel level() { return level; }

    public static MemoryLimitResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MemoryLimitResult");
        Builder builder = builder();
        Object rawChanged = Wire.required(object, "changed");
        builder.changed(Wire.bool(rawChanged, "MemoryLimitResult.changed"));
        Object rawLevel = Wire.required(object, "level");
        builder.level(MemoryPressureLevel.fromWire(rawLevel));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "changed", changed);
        Wire.put(object, "level", level);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MemoryLimitResult that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(level, that.level);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, level); }

    @Override
    public String toString() { return "MemoryLimitResult" + toWire(); }

    public static final class Builder {
        private Boolean changed;
        private boolean changedSet;
        private MemoryPressureLevel level;
        private boolean levelSet;

        public Builder changed(boolean value) {
            this.changed = value;
            this.changedSet = true;
            return this;
        }
        public Builder level(MemoryPressureLevel value) {
            this.level = value;
            this.levelSet = true;
            return this;
        }
        public MemoryLimitResult build() { return new MemoryLimitResult(this); }
    }
}
