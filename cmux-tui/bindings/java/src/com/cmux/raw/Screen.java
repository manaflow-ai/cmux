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
    private final Field<List<LayoutColumn>> columns;
    private final UInt64 id;
    private final Layout layout;
    private final String name;
    private final List<Pane> panes;
    private final Field<String> shortId;
    private final Field<Double> viewportBaseWidth;
    private final Field<List<ViewportSplit>> viewportSplits;
    private final UInt64 zoomedPane;

    private Screen(Builder builder) {
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = builder.active;
        if (!builder.activePaneSet) throw new IllegalArgumentException("active_pane is required");
        this.activePane = Wire.nonNull(builder.activePane, "active_pane");
        this.columns = builder.columns.map(value -> List.copyOf(value));
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        if (!builder.panesSet) throw new IllegalArgumentException("panes is required");
        this.panes = List.copyOf(Wire.nonNull(builder.panes, "panes"));
        this.shortId = builder.shortId;
        this.viewportBaseWidth = builder.viewportBaseWidth;
        this.viewportSplits = builder.viewportSplits.map(value -> List.copyOf(value));
        if (!builder.zoomedPaneSet) throw new IllegalArgumentException("zoomed_pane is required");
        this.zoomedPane = builder.zoomedPane;
    }

    public static Builder builder() { return new Builder(); }

    public boolean active() { return active; }
    public UInt64 activePane() { return activePane; }
    public Field<List<LayoutColumn>> columns() { return columns; }
    public UInt64 id() { return id; }
    public Layout layout() { return layout; }
    public String name() { return name; }
    public List<Pane> panes() { return panes; }
    public Field<String> shortId() { return shortId; }
    public Field<Double> viewportBaseWidth() { return viewportBaseWidth; }
    public Field<List<ViewportSplit>> viewportSplits() { return viewportSplits; }
    public UInt64 zoomedPane() { return zoomedPane; }

    public static Screen fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Screen");
        Builder builder = builder();
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.bool(rawActive, "Screen.active"));
        Object rawActivePane = Wire.required(object, "active_pane");
        builder.activePane(Wire.uint64(rawActivePane, "Screen.active_pane"));
        Object rawColumns = Wire.optional(object, "columns");
        if (!Wire.isMissing(rawColumns)) {
            builder.columns(Wire.array(rawColumns, "Screen.columns", item -> LayoutColumn.fromWire(item)));
        }
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
        Object rawViewportBaseWidth = Wire.optional(object, "viewport_base_width");
        if (!Wire.isMissing(rawViewportBaseWidth)) {
            builder.viewportBaseWidth(Wire.float64(rawViewportBaseWidth, "Screen.viewport_base_width"));
        }
        Object rawViewportSplits = Wire.optional(object, "viewport_splits");
        if (!Wire.isMissing(rawViewportSplits)) {
            builder.viewportSplits(Wire.array(rawViewportSplits, "Screen.viewport_splits", item -> ViewportSplit.fromWire(item)));
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
        Wire.put(object, "columns", columns);
        Wire.put(object, "id", id);
        Wire.put(object, "layout", layout);
        Wire.put(object, "name", name);
        Wire.put(object, "panes", panes);
        Wire.put(object, "short_id", shortId);
        Wire.put(object, "viewport_base_width", viewportBaseWidth);
        Wire.put(object, "viewport_splits", viewportSplits);
        Wire.put(object, "zoomed_pane", zoomedPane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Screen that)) return false;
        return Objects.equals(active, that.active) && Objects.equals(activePane, that.activePane) && Objects.equals(columns, that.columns) && Objects.equals(id, that.id) && Objects.equals(layout, that.layout) && Objects.equals(name, that.name) && Objects.equals(panes, that.panes) && Objects.equals(shortId, that.shortId) && Objects.equals(viewportBaseWidth, that.viewportBaseWidth) && Objects.equals(viewportSplits, that.viewportSplits) && Objects.equals(zoomedPane, that.zoomedPane);
    }

    @Override
    public int hashCode() { return Objects.hash(active, activePane, columns, id, layout, name, panes, shortId, viewportBaseWidth, viewportSplits, zoomedPane); }

    @Override
    public String toString() { return "Screen" + toWire(); }

    public static final class Builder {
        private Boolean active;
        private boolean activeSet;
        private UInt64 activePane;
        private boolean activePaneSet;
        private Field<List<LayoutColumn>> columns = Field.omitted();
        private UInt64 id;
        private boolean idSet;
        private Layout layout;
        private boolean layoutSet;
        private String name;
        private boolean nameSet;
        private List<Pane> panes;
        private boolean panesSet;
        private Field<String> shortId = Field.omitted();
        private Field<Double> viewportBaseWidth = Field.omitted();
        private Field<List<ViewportSplit>> viewportSplits = Field.omitted();
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
        public Builder columns(List<LayoutColumn> value) {
            this.columns = Field.of(value);
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
        public Builder viewportBaseWidth(Double value) {
            this.viewportBaseWidth = Field.of(value);
            return this;
        }
        public Builder viewportSplits(List<ViewportSplit> value) {
            this.viewportSplits = Field.of(value);
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
