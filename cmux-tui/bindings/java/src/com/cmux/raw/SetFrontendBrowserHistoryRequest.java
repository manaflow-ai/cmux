// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-frontend-browser-history request. Protocol v12; authority: control. */
public final class SetFrontendBrowserHistoryRequest implements WireValue {
    private final Object history;
    private final UInt64 surface;

    private SetFrontendBrowserHistoryRequest(Builder builder) {
        if (!builder.historySet) throw new IllegalArgumentException("history is required");
        this.history = builder.history == null ? null : Wire.immutableJson(builder.history);
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Object history() { return history; }
    public UInt64 surface() { return surface; }

    public static SetFrontendBrowserHistoryRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetFrontendBrowserHistoryRequest");
        Builder builder = builder();
        Object rawHistory = Wire.required(object, "history");
        builder.history(rawHistory == null ? null : Wire.immutableJson(rawHistory));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SetFrontendBrowserHistoryRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "history", history);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetFrontendBrowserHistoryRequest that)) return false;
        return Objects.equals(history, that.history) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(history, surface); }

    @Override
    public String toString() { return "SetFrontendBrowserHistoryRequest" + toWire(); }

    public static final class Builder {
        private Object history;
        private boolean historySet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder history(Object value) {
            this.history = value;
            this.historySet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SetFrontendBrowserHistoryRequest build() { return new SetFrontendBrowserHistoryRequest(this); }
    }
}
