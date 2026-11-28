// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class Screen implements WireValue {
    private final boolean active;
    private final UInt64 activePane;
    private final UInt64 id;
    private final Layout layout;
    private final String name;
    private final List<Pane> panes;
    private final Field<String> shortId;
    private final UInt64 zoomedPane;

    private Screen(Builder builder) {
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = builder.active;
        if (!builder.activePaneSet) throw new IllegalArgumentException("active_pane is required");
        this.activePane = Wire.nonNull(builder.activePane, "active_pane");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        if (!builder.panesSet) throw new IllegalArgumentException("panes is required");
        this.panes = List.copyOf(Wire.nonNull(builder.panes, "panes"));
        this.shortId = builder.shortId;
        if (!builder.zoomedPaneSet) throw new IllegalArgumentException("zoomed_pane is required");
        this.zoomedPane = builder.zoomedPane;
    }

    public static Builder builder() { return new Builder(); }

    public boolean active() { return active; }
    public UInt64 activePane() { return activePane; }
    public UInt64 id() { return id; }
    public Layout layout() { return layout; }
    public String name() { return name; }
    public List<Pane> panes() { return panes; }
    public Field<String> shortId() { return shortId; }
    public UInt64 zoomedPane() { return zoomedPane; }

    public static Screen fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Screen");
        Builder builder = builder();
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.bool(rawActive, "Screen.active"));
        Object rawActivePane = Wire.required(object, "active_pane");
        builder.activePane(Wire.uint64(rawActivePane, "Screen.active_pane"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "Screen.id"));
        Object rawLayout = Wire.required(object, "layout");
        builder.layout(Layout.fromWire(rawLayout));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "Screen.name"));
        Object rawPanes = Wire.required(object, "panes");
        builder.panes(Wire.array(rawPanes, "Screen.panes", item -> Pane.fromWire(item)));
        Object rawShortId = Wire.optional(object, "short_id");
        if (!Wire.isMissing(rawShortId)) {
            builder.shortId(Wire.string(rawShortId, "Screen.short_id"));
        }
        Object rawZoomedPane = Wire.required(object, "zoomed_pane");
        builder.zoomedPane(rawZoomedPane == null ? null : Wire.uint64(rawZoomedPane, "Screen.zoomed_pane"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "active", active);
        Wire.put(object, "active_pane", activePane);
        Wire.put(object, "id", id);
        Wire.put(object, "layout", layout);
        Wire.put(object, "name", name);
        Wire.put(object, "panes", panes);
        Wire.put(object, "short_id", shortId);
        Wire.put(object, "zoomed_pane", zoomedPane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Screen that)) return false;
        return Objects.equals(active, that.active) && Objects.equals(activePane, that.activePane) && Objects.equals(id, that.id) && Objects.equals(layout, that.layout) && Objects.equals(name, that.name) && Objects.equals(panes, that.panes) && Objects.equals(shortId, that.shortId) && Objects.equals(zoomedPane, that.zoomedPane);
    }

    @Override
    public int hashCode() { return Objects.hash(active, activePane, id, layout, name, panes, shortId, zoomedPane); }

    @Override
    public String toString() { return "Screen" + toWire(); }

    public static final class Builder {
        private Boolean active;
        private boolean activeSet;
        private UInt64 activePane;
        private boolean activePaneSet;
        private UInt64 id;
        private boolean idSet;
        private Layout layout;
        private boolean layoutSet;
        private String name;
        private boolean nameSet;
        private List<Pane> panes;
        private boolean panesSet;
        private Field<String> shortId = Field.omitted();
        private UInt64 zoomedPane;
        private boolean zoomedPaneSet;

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
        public Builder layout(Layout value) {
            this.layout = value;
            this.layoutSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder panes(List<Pane> value) {
            this.panes = value;
            this.panesSet = true;
            return this;
        }
        public Builder shortId(String value) {
            this.shortId = Field.of(value);
            return this;
        }
        public Builder zoomedPane(UInt64 value) {
            this.zoomedPane = value;
            this.zoomedPaneSet = true;
            return this;
        }
        public Screen build() { return new Screen(this); }
    }
}
