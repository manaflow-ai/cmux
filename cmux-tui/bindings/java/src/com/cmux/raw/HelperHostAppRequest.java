// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable helper-host-app request. Protocol v12; authority: local-admin. */
public final class HelperHostAppRequest implements WireValue {

    private HelperHostAppRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static HelperHostAppRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HelperHostAppRequest");
        Builder builder = builder();
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HelperHostAppRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "HelperHostAppRequest" + toWire(); }

    public static final class Builder {

        public HelperHostAppRequest build() { return new HelperHostAppRequest(this); }
    }
}
