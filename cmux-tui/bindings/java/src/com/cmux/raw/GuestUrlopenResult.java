// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class GuestUrlopenResult implements WireValue {
    private final boolean opened;

    private GuestUrlopenResult(Builder builder) {
        if (!builder.openedSet) throw new IllegalArgumentException("opened is required");
        this.opened = builder.opened;
    }

    public static Builder builder() { return new Builder(); }

    public boolean opened() { return opened; }

    public static GuestUrlopenResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GuestUrlopenResult");
        Builder builder = builder();
        Object rawOpened = Wire.required(object, "opened");
        builder.opened(Wire.bool(rawOpened, "GuestUrlopenResult.opened"));
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
        if (!(other instanceof GuestUrlopenResult that)) return false;
        return Objects.equals(opened, that.opened);
    }

    @Override
    public int hashCode() { return Objects.hash(opened); }

    @Override
    public String toString() { return "GuestUrlopenResult" + toWire(); }

    public static final class Builder {
        private Boolean opened;
        private boolean openedSet;

        public Builder opened(boolean value) {
            this.opened = value;
            this.openedSet = true;
            return this;
        }
        public GuestUrlopenResult build() { return new GuestUrlopenResult(this); }
    }
}
