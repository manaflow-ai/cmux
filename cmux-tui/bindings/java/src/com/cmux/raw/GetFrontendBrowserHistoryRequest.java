// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable get-frontend-browser-history request. Protocol v12; authority: control. */
public final class GetFrontendBrowserHistoryRequest implements WireValue {
    private final UInt64 surface;

    private GetFrontendBrowserHistoryRequest(Builder builder) {
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 surface() { return surface; }

    public static GetFrontendBrowserHistoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GetFrontendBrowserHistoryRequest");
        Builder builder = builder();
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "GetFrontendBrowserHistoryRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GetFrontendBrowserHistoryRequest that)) return false;
        return Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(surface); }

    @Override
    public String toString() { return "GetFrontendBrowserHistoryRequest" + toWire(); }

    public static final class Builder {
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public GetFrontendBrowserHistoryRequest build() { return new GetFrontendBrowserHistoryRequest(this); }
    }
}
