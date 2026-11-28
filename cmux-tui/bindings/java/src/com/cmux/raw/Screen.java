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
    /** The screen color. */
    private final Field<String> color;
    /** The screen's layout columns. */
    private final Field<List<LayoutColumnNode>> columns;
    /** floating-panes-v1: panes above the tiled layout, back to front. */
    private final Field<List<FloatingPane>> floating;
    /** The screen group the screen is in. */
    private final Field<String> group;
    /** split-divider-visibility-v1: splits whose divider is hidden. */
    private final Field<List<UInt64>> hiddenDividers;
    /** The screen icon. */
    private final Field<String> icon;
    private final UInt64 id;
    private final Layout layout;
    private final String name;
    private final List<Pane> panes;
    /** The screen is pinned. */
    private final Field<Boolean> pinned;
    /** quick-terminal-v1: the screen's quick terminal. */
    private final Field<Object> quickTerminal;
    /** The screen's public id. */
    private final Field<String> resourceId;
    private final Field<String> shortId;
    /** The viewport width the split widths are relative to. */
    private final Field<Double> viewportBaseWidth;
    /** Viewport widths of splits. */
    private final Field<List<ViewportSplitWidth>> viewportSplits;
    private final UInt64 zoomedPane;

    private Screen(Builder builder) {
        if (!builder.activeSet) throw new IllegalArgumentException("active is required");
        this.active = builder.active;
        if (!builder.activePaneSet) throw new IllegalArgumentException("active_pane is required");
        this.activePane = Wire.nonNull(builder.activePane, "active_pane");
        this.color = builder.color;
        this.columns = builder.columns.map(value -> List.copyOf(value));
        this.floating = builder.floating.map(value -> List.copyOf(value));
        this.group = builder.group;
        this.hiddenDividers = builder.hiddenDividers.map(value -> List.copyOf(value));
        this.icon = builder.icon;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        if (!builder.panesSet) throw new IllegalArgumentException("panes is required");
        this.panes = List.copyOf(Wire.nonNull(builder.panes, "panes"));
        this.pinned = builder.pinned;
        this.quickTerminal = builder.quickTerminal.map(value -> Wire.immutableJson(value));
        this.resourceId = builder.resourceId;
        this.shortId = builder.shortId;
        this.viewportBaseWidth = builder.viewportBaseWidth;
        this.viewportSplits = builder.viewportSplits.map(value -> List.copyOf(value));
        if (!builder.zoomedPaneSet) throw new IllegalArgumentException("zoomed_pane is required");
        this.zoomedPane = builder.zoomedPane;
    }

    public static Builder builder() { return new Builder(); }

    public boolean active() { return active; }
    public UInt64 activePane() { return activePane; }
    public Field<String> color() { return color; }
    public Field<List<LayoutColumnNode>> columns() { return columns; }
    public Field<List<FloatingPane>> floating() { return floating; }
    public Field<String> group() { return group; }
    public Field<List<UInt64>> hiddenDividers() { return hiddenDividers; }
    public Field<String> icon() { return icon; }
    public UInt64 id() { return id; }
    public Layout layout() { return layout; }
    public String name() { return name; }
    public List<Pane> panes() { return panes; }
    public Field<Boolean> pinned() { return pinned; }
    public Field<Object> quickTerminal() { return quickTerminal; }
    public Field<String> resourceId() { return resourceId; }
    public Field<String> shortId() { return shortId; }
    public Field<Double> viewportBaseWidth() { return viewportBaseWidth; }
    public Field<List<ViewportSplitWidth>> viewportSplits() { return viewportSplits; }
    public UInt64 zoomedPane() { return zoomedPane; }

    public static Screen fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "Screen");
        Builder builder = builder();
        Object rawActive = Wire.required(object, "active");
        builder.active(Wire.bool(rawActive, "Screen.active"));
        Object rawActivePane = Wire.required(object, "active_pane");
        builder.activePane(Wire.uint64(rawActivePane, "Screen.active_pane"));
        Object rawColor = Wire.optional(object, "color");
        if (!Wire.isMissing(rawColor)) {
            builder.color(rawColor == null ? null : Wire.string(rawColor, "Screen.color"));
        }
        Object rawColumns = Wire.optional(object, "columns");
        if (!Wire.isMissing(rawColumns)) {
            builder.columns(Wire.array(rawColumns, "Screen.columns", item -> LayoutColumnNode.fromWire(item)));
        }
        Object rawFloating = Wire.optional(object, "floating");
        if (!Wire.isMissing(rawFloating)) {
            builder.floating(Wire.array(rawFloating, "Screen.floating", item -> FloatingPane.fromWire(item)));
        }
        Object rawGroup = Wire.optional(object, "group");
        if (!Wire.isMissing(rawGroup)) {
            builder.group(rawGroup == null ? null : Wire.string(rawGroup, "Screen.group"));
        }
        Object rawHiddenDividers = Wire.optional(object, "hidden_dividers");
        if (!Wire.isMissing(rawHiddenDividers)) {
            builder.hiddenDividers(Wire.array(rawHiddenDividers, "Screen.hidden_dividers", item -> Wire.uint64(item, "Screen.hidden_dividers item")));
        }
        Object rawIcon = Wire.optional(object, "icon");
        if (!Wire.isMissing(rawIcon)) {
            builder.icon(rawIcon == null ? null : Wire.string(rawIcon, "Screen.icon"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "Screen.id"));
        Object rawLayout = Wire.required(object, "layout");
        builder.layout(Layout.fromWire(rawLayout));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "Screen.name"));
        Object rawPanes = Wire.required(object, "panes");
        builder.panes(Wire.array(rawPanes, "Screen.panes", item -> Pane.fromWire(item)));
        Object rawPinned = Wire.optional(object, "pinned");
        if (!Wire.isMissing(rawPinned)) {
            builder.pinned(Wire.bool(rawPinned, "Screen.pinned"));
        }
        Object rawQuickTerminal = Wire.optional(object, "quick_terminal");
        if (!Wire.isMissing(rawQuickTerminal)) {
            builder.quickTerminal(Wire.immutableJson(ProtocolSupport.nonNull(rawQuickTerminal, "Screen.quick_terminal")));
        }
        Object rawResourceId = Wire.optional(object, "resource_id");
        if (!Wire.isMissing(rawResourceId)) {
            builder.resourceId(rawResourceId == null ? null : Wire.string(rawResourceId, "Screen.resource_id"));
        }
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
            builder.viewportSplits(Wire.array(rawViewportSplits, "Screen.viewport_splits", item -> ViewportSplitWidth.fromWire(item)));
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
        Wire.put(object, "color", color);
        Wire.put(object, "columns", columns);
        Wire.put(object, "floating", floating);
        Wire.put(object, "group", group);
        Wire.put(object, "hidden_dividers", hiddenDividers);
        Wire.put(object, "icon", icon);
        Wire.put(object, "id", id);
        Wire.put(object, "layout", layout);
        Wire.put(object, "name", name);
        Wire.put(object, "panes", panes);
        Wire.put(object, "pinned", pinned);
        Wire.put(object, "quick_terminal", quickTerminal);
        Wire.put(object, "resource_id", resourceId);
        Wire.put(object, "short_id", shortId);
        Wire.put(object, "viewport_base_width", viewportBaseWidth);
        Wire.put(object, "viewport_splits", viewportSplits);
        Wire.put(object, "zoomed_pane", zoomedPane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof Screen that)) return false;
        return Objects.equals(active, that.active) && Objects.equals(activePane, that.activePane) && Objects.equals(color, that.color) && Objects.equals(columns, that.columns) && Objects.equals(floating, that.floating) && Objects.equals(group, that.group) && Objects.equals(hiddenDividers, that.hiddenDividers) && Objects.equals(icon, that.icon) && Objects.equals(id, that.id) && Objects.equals(layout, that.layout) && Objects.equals(name, that.name) && Objects.equals(panes, that.panes) && Objects.equals(pinned, that.pinned) && Objects.equals(quickTerminal, that.quickTerminal) && Objects.equals(resourceId, that.resourceId) && Objects.equals(shortId, that.shortId) && Objects.equals(viewportBaseWidth, that.viewportBaseWidth) && Objects.equals(viewportSplits, that.viewportSplits) && Objects.equals(zoomedPane, that.zoomedPane);
    }

    @Override
    public int hashCode() { return Objects.hash(active, activePane, color, columns, floating, group, hiddenDividers, icon, id, layout, name, panes, pinned, quickTerminal, resourceId, shortId, viewportBaseWidth, viewportSplits, zoomedPane); }

    @Override
    public String toString() { return "Screen" + toWire(); }

    public static final class Builder {
        private Boolean active;
        private boolean activeSet;
        private UInt64 activePane;
        private boolean activePaneSet;
        private Field<String> color = Field.omitted();
        private Field<List<LayoutColumnNode>> columns = Field.omitted();
        private Field<List<FloatingPane>> floating = Field.omitted();
        private Field<String> group = Field.omitted();
        private Field<List<UInt64>> hiddenDividers = Field.omitted();
        private Field<String> icon = Field.omitted();
        private UInt64 id;
        private boolean idSet;
        private Layout layout;
        private boolean layoutSet;
        private String name;
        private boolean nameSet;
        private List<Pane> panes;
        private boolean panesSet;
        private Field<Boolean> pinned = Field.omitted();
        private Field<Object> quickTerminal = Field.omitted();
        private Field<String> resourceId = Field.omitted();
        private Field<String> shortId = Field.omitted();
        private Field<Double> viewportBaseWidth = Field.omitted();
        private Field<List<ViewportSplitWidth>> viewportSplits = Field.omitted();
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
        public Builder color(String value) {
            this.color = Field.ofNullable(value);
            return this;
        }
        public Builder columns(List<LayoutColumnNode> value) {
            this.columns = Field.of(value);
            return this;
        }
        public Builder floating(List<FloatingPane> value) {
            this.floating = Field.of(value);
            return this;
        }
        public Builder group(String value) {
            this.group = Field.ofNullable(value);
            return this;
        }
        public Builder hiddenDividers(List<UInt64> value) {
            this.hiddenDividers = Field.of(value);
            return this;
        }
        public Builder icon(String value) {
            this.icon = Field.ofNullable(value);
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
        public Builder pinned(Boolean value) {
            this.pinned = Field.of(value);
            return this;
        }
        public Builder quickTerminal(Object value) {
            this.quickTerminal = Field.of(value);
            return this;
        }
        public Builder resourceId(String value) {
            this.resourceId = Field.ofNullable(value);
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
        public Builder viewportSplits(List<ViewportSplitWidth> value) {
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
