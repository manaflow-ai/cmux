// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable unregister-browser-provider request. Protocol v10; authority: local-admin. */
public final class UnregisterBrowserProviderRequest implements WireValue {

    private UnregisterBrowserProviderRequest(Builder builder) {
    }

    public static Builder builder() { return new Builder(); }


    public static UnregisterBrowserProviderRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UnregisterBrowserProviderRequest");
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
        if (!(other instanceof UnregisterBrowserProviderRequest that)) return false;
        return true;
    }

    @Override
    public int hashCode() { return Objects.hash(); }

    @Override
    public String toString() { return "UnregisterBrowserProviderRequest" + toWire(); }

    public static final class Builder {

        public UnregisterBrowserProviderRequest build() { return new UnregisterBrowserProviderRequest(this); }
    }
}
