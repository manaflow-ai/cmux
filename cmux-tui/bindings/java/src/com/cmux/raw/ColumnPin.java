// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ColumnPin implements WireValue {
    private final Field<Boolean> allowTabs;
    private final String edge;
    private final String mode;
    private final Field<Boolean> permanent;
    private final Field<Boolean> pinned;
    private final Field<String> role;

    private ColumnPin(Builder builder) {
        this.allowTabs = builder.allowTabs;
        if (!builder.edgeSet) throw new IllegalArgumentException("edge is required");
        this.edge = Wire.nonNull(builder.edge, "edge");
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        this.permanent = builder.permanent;
        this.pinned = builder.pinned;
        this.role = builder.role;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> allowTabs() { return allowTabs; }
    public String edge() { return edge; }
    public String mode() { return mode; }
    public Field<Boolean> permanent() { return permanent; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<String> role() { return role; }

    public static ColumnPin fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ColumnPin");
        Builder builder = builder();
        Object rawAllowTabs = Wire.optional(object, "allow_tabs");
        if (!Wire.isMissing(rawAllowTabs)) {
            builder.allowTabs(Wire.bool(rawAllowTabs, "ColumnPin.allow_tabs"));
        }
        Object rawEdge = Wire.required(object, "edge");
        builder.edge(Wire.string(rawEdge, "ColumnPin.edge"));
        Object rawMode = Wire.required(object, "mode");
        builder.mode(Wire.string(rawMode, "ColumnPin.mode"));
        Object rawPermanent = Wire.optional(object, "permanent");
        if (!Wire.isMissing(rawPermanent)) {
            builder.permanent(Wire.bool(rawPermanent, "ColumnPin.permanent"));
        }
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(Wire.bool(rawPinned, "ColumnPin.pinned"));
        }
        Object rawRole = Wire.optional(object, "role");
        if (!Wire.isMissing(rawRole)) {
            builder.role(rawRole == null ? null : Wire.string(rawRole, "ColumnPin.role"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "allow_tabs", allowTabs);
        Wire.put(object, "edge", edge);
        Wire.put(object, "mode", mode);
        Wire.put(object, "permanent", permanent);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "role", role);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ColumnPin that)) return false;
        return Objects.equals(allowTabs, that.allowTabs) && Objects.equals(edge, that.edge) && Objects.equals(mode, that.mode) && Objects.equals(permanent, that.permanent) && Objects.equals(pinned, that.pinned) && Objects.equals(role, that.role);
    }

    @Override
    public int hashCode() { return Objects.hash(allowTabs, edge, mode, permanent, pinned, role); }

    @Override
    public String toString() { return "ColumnPin" + toWire(); }

    public static final class Builder {
        private Field<Boolean> allowTabs = Field.omitted();
        private String edge;
        private boolean edgeSet;
        private String mode;
        private boolean modeSet;
        private Field<Boolean> permanent = Field.omitted();
        private Field<Boolean> pinned = Field.omitted();
        private Field<String> role = Field.omitted();

        public Builder allowTabs(Boolean value) {
            this.allowTabs = Field.of(value);
            return this;
        }
        public Builder edge(String value) {
            this.edge = value;
            this.edgeSet = true;
            return this;
        }
        public Builder mode(String value) {
            this.mode = value;
            this.modeSet = true;
            return this;
        }
        public Builder permanent(Boolean value) {
            this.permanent = Field.of(value);
            return this;
        }
        public Builder pinned(Boolean value) {
            this.pinned = Field.of(value);
            return this;
        }
        public Builder role(String value) {
            this.role = Field.ofNullable(value);
            return this;
        }
        public ColumnPin build() { return new ColumnPin(this); }
    }
}
