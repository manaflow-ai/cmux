// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class IdsResult implements WireValue {
    private final List<IdMapping> ids;

    private IdsResult(Builder builder) {
        if (!builder.idsSet) throw new IllegalArgumentException("ids is required");
        this.ids = List.copyOf(Wire.nonNull(builder.ids, "ids"));
    }

    public static Builder builder() { return new Builder(); }

    public List<IdMapping> ids() { return ids; }

    public static IdsResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "IdsResult");
        Builder builder = builder();
        Object rawIds = Wire.required(object, "ids");
        builder.ids(Wire.array(rawIds, "IdsResult.ids", item -> IdMapping.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "ids", ids);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof IdsResult that)) return false;
        return Objects.equals(ids, that.ids);
    }

    @Override
    public int hashCode() { return Objects.hash(ids); }

    @Override
    public String toString() { return "IdsResult" + toWire(); }

    public static final class Builder {
        private List<IdMapping> ids;
        private boolean idsSet;

        public Builder ids(List<IdMapping> value) {
            this.ids = value;
            this.idsSet = true;
            return this;
        }
        public IdsResult build() { return new IdsResult(this); }
    }
}
