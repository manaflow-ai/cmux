// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SelectionScreen implements WireValue {
    private final boolean active;
    private final UInt64 activePane;
    private final UInt64 id;
    private final List<SelectionPane> panes;

    private SelectionScreen(Builder builder) {
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = builder.active;
        if (!builder.activePaneSet) throw new IllegalArgumentException("active_pane is required");
        this.activePane = Wire.nonNull(builder.activePane, "active_pane");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.panesSet) throw new IllegalArgumentException("panes is required");
        this.panes = List.copyOf(Wire.nonNull(builder.panes, "panes"));
    }

    public static Builder builder() { return new Builder(); }

    public boolean active() { return active; }
    public UInt64 activePane() { return activePane; }
    public UInt64 id() { return id; }
    public List<SelectionPane> panes() { return panes; }

    public static SelectionScreen fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SelectionScreen");
        Builder builder = builder();
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.bool(rawActive, "SelectionScreen.active"));
        Object rawActivePane = Wire.required(object, "active_pane");
        builder.activePane(Wire.uint64(rawActivePane, "SelectionScreen.active_pane"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "SelectionScreen.id"));
        Object rawPanes = Wire.required(object, "panes");
        builder.panes(Wire.array(rawPanes, "SelectionScreen.panes", item -> SelectionPane.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "active", active);
        Wire.put(object, "active_pane", activePane);
        Wire.put(object, "id", id);
        Wire.put(object, "panes", panes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SelectionScreen that)) return false;
        return Objects.equals(active, that.active) && Objects.equals(activePane, that.activePane) && Objects.equals(id, that.id) && Objects.equals(panes, that.panes);
    }

    @Override
    public int hashCode() { return Objects.hash(active, activePane, id, panes); }

    @Override
    public String toString() { return "SelectionScreen" + toWire(); }

    public static final class Builder {
        private Boolean active;
        private boolean activeSet;
        private UInt64 activePane;
        private boolean activePaneSet;
        private UInt64 id;
        private boolean idSet;
        private List<SelectionPane> panes;
        private boolean panesSet;

        public Builder active(boolean value) {
            this.active = value;
            this.activeSet = true;
            return this;
        }
        public Builder activePane(UInt64 value) {
            this.activePane = value;
            this.activePaneSet = true;
            return this;
        }
        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder panes(List<SelectionPane> value) {
            this.panes = value;
            this.panesSet = true;
            return this;
        }
        public SelectionScreen build() { return new SelectionScreen(this); }
    }
}
