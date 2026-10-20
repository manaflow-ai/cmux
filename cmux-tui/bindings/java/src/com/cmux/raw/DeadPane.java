// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class DeadPane implements WireValue {
    private final UInt64 id;

    private DeadPane(Builder builder) {
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
    }

    public static Builder builder() { return new Builder(); }

    public Boolean dead() { return true; }
    public UInt64 id() { return id; }

    public static DeadPane fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeadPane");
        Builder builder = builder();
        Object rawDead = Wire.required(object, "dead");
        ProtocolSupport.literal(rawDead, true, "DeadPane.dead");
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "DeadPane.id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dead", true);
        Wire.put(object, "id", id);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeadPane that)) return false;
        return Objects.equals(id, that.id);
    }

    @Override
    public int hashCode() { return Objects.hash(id); }

    @Override
    public String toString() { return "DeadPane" + toWire(); }

    public static final class Builder {
        private UInt64 id;
        private boolean idSet;

        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public DeadPane build() { return new DeadPane(this); }
    }
}
