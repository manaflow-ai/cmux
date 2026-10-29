// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class EnergySetResult implements WireValue {
    private final boolean changed;
    private final boolean saver;

    private EnergySetResult(Builder builder) {
        if (!builder.changedSet) throw new IllegalArgumentException("changed is required");
        this.changed = builder.changed;
        if (!builder.saverSet) throw new IllegalArgumentException("saver is required");
        this.saver = builder.saver;
    }

    public static Builder builder() { return new Builder(); }

    public boolean changed() { return changed; }
    public boolean saver() { return saver; }

    public static EnergySetResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "EnergySetResult");
        Builder builder = builder();
        Object rawChanged = Wire.required(object, "changed");
        builder.changed(Wire.bool(rawChanged, "EnergySetResult.changed"));
        Object rawSaver = Wire.required(object, "saver");
        builder.saver(Wire.bool(rawSaver, "EnergySetResult.saver"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "changed", changed);
        Wire.put(object, "saver", saver);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof EnergySetResult that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(saver, that.saver);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, saver); }

    @Override
    public String toString() { return "EnergySetResult" + toWire(); }

    public static final class Builder {
        private Boolean changed;
        private boolean changedSet;
        private Boolean saver;
        private boolean saverSet;

        public Builder changed(boolean value) {
            this.changed = value;
            this.changedSet = true;
            return this;
        }
        public Builder saver(boolean value) {
            this.saver = value;
            this.saverSet = true;
            return this;
        }
        public EnergySetResult build() { return new EnergySetResult(this); }
    }
}
