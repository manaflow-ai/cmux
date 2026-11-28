// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ColumnDock implements WireValue {
    /** `pinned-dock-v1`: a pinned column takes more tabs; omitted when false. */
    private final Field<Boolean> allowTabs;
    /** left or right (`dock-columns-v1`), top or bottom (also `edge-docks-v1`). */
    private final ColumnDockEdge edge;
    /** `docked` takes its width out of the scrolling area; `overlay` floats above the scrolling columns. */
    private final ColumnDockMode mode;
    /** `permanent-dock-v1`: the column stays docked on `edge` for every client; omitted when false. */
    private final Field<Boolean> permanent;
    /** `pinned-dock-v1`: a pinned column (the Home dock); omitted when false. */
    private final Field<Boolean> pinned;
    /** `dock-column-role-v1`: what the column is for; omitted when unset. */
    private final Field<ColumnDockRole> role;
    private final Map<String, Object> additionalProperties;

    private ColumnDock(Builder builder) {
        this.allowTabs = builder.allowTabs;
        if (!builder.edgeSet) throw new IllegalArgumentException("edge is required");
        this.edge = Wire.nonNull(builder.edge, "edge");
        if (!builder.modeSet) throw new IllegalArgumentException("mode is required");
        this.mode = Wire.nonNull(builder.mode, "mode");
        this.permanent = builder.permanent;
        this.pinned = builder.pinned;
        this.role = builder.role;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> allowTabs() { return allowTabs; }
    public ColumnDockEdge edge() { return edge; }
    public ColumnDockMode mode() { return mode; }
    public Field<Boolean> permanent() { return permanent; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<ColumnDockRole> role() { return role; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ColumnDock fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ColumnDock");
        Builder builder = builder();
        Object rawAllowTabs = Wire.optional(object, "allow_tabs");
        if (!Wire.isMissing(rawAllowTabs)) {
            builder.allowTabs(Wire.bool(rawAllowTabs, "ColumnDock.allow_tabs"));
        }
        Object rawEdge = Wire.required(object, "edge");
        builder.edge(ColumnDockEdge.fromWire(rawEdge));
        Object rawMode = Wire.required(object, "mode");
        builder.mode(ColumnDockMode.fromWire(rawMode));
        Object rawPermanent = Wire.optional(object, "permanent");
        if (!Wire.isMissing(rawPermanent)) {
            builder.permanent(Wire.bool(rawPermanent, "ColumnDock.permanent"));
        }
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(Wire.bool(rawPinned, "ColumnDock.pinned"));
        }
        Object rawRole = Wire.optional(object, "role");
        if (!Wire.isMissing(rawRole)) {
            builder.role(ColumnDockRole.fromWire(rawRole));
        }
        List<String> known = List.of("allow_tabs", "edge", "mode", "permanent", "pinned", "role");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
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
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ColumnDock that)) return false;
        return Objects.equals(allowTabs, that.allowTabs) && Objects.equals(edge, that.edge) && Objects.equals(mode, that.mode) && Objects.equals(permanent, that.permanent) && Objects.equals(pinned, that.pinned) && Objects.equals(role, that.role) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(allowTabs, edge, mode, permanent, pinned, role, additionalProperties); }

    @Override
    public String toString() { return "ColumnDock" + toWire(); }

    public static final class Builder {
        private Field<Boolean> allowTabs = Field.omitted();
        private ColumnDockEdge edge;
        private boolean edgeSet;
        private ColumnDockMode mode;
        private boolean modeSet;
        private Field<Boolean> permanent = Field.omitted();
        private Field<Boolean> pinned = Field.omitted();
        private Field<ColumnDockRole> role = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder allowTabs(Boolean value) {
            this.allowTabs = Field.of(value);
            return this;
        }
        public Builder edge(ColumnDockEdge value) {
            this.edge = value;
            this.edgeSet = true;
            return this;
        }
        public Builder mode(ColumnDockMode value) {
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
        public Builder role(ColumnDockRole value) {
            this.role = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ColumnDock build() { return new ColumnDock(this); }
    }
}
