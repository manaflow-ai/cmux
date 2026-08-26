// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ExportedPane implements WireValue {
    private final UInt64 pane;
    private final List<UInt64> surfaces;

    private ExportedPane(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.surfacesSet) throw new IllegalArgumentException("surfaces is required");
        this.surfaces = List.copyOf(Wire.nonNull(builder.surfaces, "surfaces"));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public List<UInt64> surfaces() { return surfaces; }

    public static ExportedPane fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ExportedPane");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "ExportedPane.pane"));
        Object rawSurfaces = Wire.required(object, "surfaces");
        builder.surfaces(Wire.array(rawSurfaces, "ExportedPane.surfaces", item -> Wire.uint64(item, "ExportedPane.surfaces item")));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "surfaces", surfaces);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ExportedPane that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(surfaces, that.surfaces);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, surfaces); }

    @Override
    public String toString() { return "ExportedPane" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private List<UInt64> surfaces;
        private boolean surfacesSet;

        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder surfaces(List<UInt64> value) {
            this.surfaces = value;
            this.surfacesSet = true;
            return this;
        }
        public ExportedPane build() { return new ExportedPane(this); }
    }
}
