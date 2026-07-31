// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable rename-pane request. Protocol v5; authority: control. */
public final class RenamePaneRequest implements WireValue {
    private final String name;
    private final UInt64 pane;

    private RenamePaneRequest(Builder builder) {
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = Wire.nonNull(builder.name, "name");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
    }

    public static Builder builder() { return new Builder(); }

    public String name() { return name; }
    public UInt64 pane() { return pane; }

    public static RenamePaneRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenamePaneRequest");
        Builder builder = builder();
        Object rawName = Wire.required(object, "name");
        builder.name(Wire.string(rawName, "RenamePaneRequest.name"));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "RenamePaneRequest.pane"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "name", name);
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenamePaneRequest that)) return false;
        return Objects.equals(name, that.name) && Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(name, pane); }

    @Override
    public String toString() { return "RenamePaneRequest" + toWire(); }

    public static final class Builder {
        private String name;
        private boolean nameSet;
        private UInt64 pane;
        private boolean paneSet;

        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public RenamePaneRequest build() { return new RenamePaneRequest(this); }
    }
}
