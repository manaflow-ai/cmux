// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GuestUrlOpenResult implements WireValue {
    private final boolean opened;

    private GuestUrlOpenResult(Builder builder) {
        if (!builder.openedSet) throw new IllegalArgumentException("opened is required");
        this.opened = builder.opened;
    }

    public static Builder builder() { return new Builder(); }

    public boolean opened() { return opened; }

    public static GuestUrlOpenResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GuestUrlOpenResult");
        Builder builder = builder();
        Object rawOpened = Wire.required(object, "opened");
        builder.opened(Wire.bool(rawOpened, "GuestUrlOpenResult.opened"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "opened", opened);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GuestUrlOpenResult that)) return false;
        return Objects.equals(opened, that.opened);
    }

    @Override
    public int hashCode() { return Objects.hash(opened); }

    @Override
    public String toString() { return "GuestUrlOpenResult" + toWire(); }

    public static final class Builder {
        private Boolean opened;
        private boolean openedSet;

        public Builder opened(boolean value) {
            this.opened = value;
            this.openedSet = true;
            return this;
        }
        public GuestUrlOpenResult build() { return new GuestUrlOpenResult(this); }
    }
}
