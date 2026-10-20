// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LivePane implements WireValue {
    private final UInt64 activeTab;
    private final Field<UInt64> focusedAt;
    private final UInt64 id;
    private final String name;
    private final Field<String> shortId;
    private final List<Tab> tabs;

    private LivePane(Builder builder) {
        if (!builder.activeTabSet) throw new IllegalArgumentException("active_tab is required");
        this.activeTab = Wire.nonNull(builder.activeTab, "active_tab");
        this.focusedAt = builder.focusedAt;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.nameSet) throw new IllegalArgumentException("name is required");
        this.name = builder.name;
        this.shortId = builder.shortId;
        if (!builder.tabsSet) throw new IllegalArgumentException("tabs is required");
        this.tabs = List.copyOf(Wire.nonNull(builder.tabs, "tabs"));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 activeTab() { return activeTab; }
    public Field<UInt64> focusedAt() { return focusedAt; }
    public UInt64 id() { return id; }
    public String name() { return name; }
    public Field<String> shortId() { return shortId; }
    public List<Tab> tabs() { return tabs; }

    public static LivePane fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LivePane");
        Builder builder = builder();
        Object rawActiveTab = Wire.required(object, "active_tab");
        builder.activeTab(Wire.uint64(rawActiveTab, "LivePane.active_tab"));
        Object rawFocusedAt = Wire.optional(object, "focused_at");
        if (!Wire.isMissing(rawFocusedAt)) {
            builder.focusedAt(Wire.uint64(rawFocusedAt, "LivePane.focused_at"));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "LivePane.id"));
        Object rawName = Wire.required(object, "name");
        builder.name(rawName == null ? null : Wire.string(rawName, "LivePane.name"));
        Object rawShortId = Wire.optional(object, "short_id");
        if (!Wire.isMissing(rawShortId)) {
            builder.shortId(Wire.string(rawShortId, "LivePane.short_id"));
        }
        Object rawTabs = Wire.required(object, "tabs");
        builder.tabs(Wire.array(rawTabs, "LivePane.tabs", item -> Tab.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "active_tab", activeTab);
        Wire.put(object, "focused_at", focusedAt);
        Wire.put(object, "id", id);
        Wire.put(object, "name", name);
        Wire.put(object, "short_id", shortId);
        Wire.put(object, "tabs", tabs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LivePane that)) return false;
        return Objects.equals(activeTab, that.activeTab) && Objects.equals(focusedAt, that.focusedAt) && Objects.equals(id, that.id) && Objects.equals(name, that.name) && Objects.equals(shortId, that.shortId) && Objects.equals(tabs, that.tabs);
    }

    @Override
    public int hashCode() { return Objects.hash(activeTab, focusedAt, id, name, shortId, tabs); }

    @Override
    public String toString() { return "LivePane" + toWire(); }

    public static final class Builder {
        private UInt64 activeTab;
        private boolean activeTabSet;
        private Field<UInt64> focusedAt = Field.omitted();
        private UInt64 id;
        private boolean idSet;
        private String name;
        private boolean nameSet;
        private Field<String> shortId = Field.omitted();
        private List<Tab> tabs;
        private boolean tabsSet;

        public Builder activeTab(UInt64 value) {
            this.activeTab = value;
            this.activeTabSet = true;
            return this;
        }
        public Builder focusedAt(UInt64 value) {
            this.focusedAt = Field.of(value);
            return this;
        }
        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder name(String value) {
            this.name = value;
            this.nameSet = true;
            return this;
        }
        public Builder shortId(String value) {
            this.shortId = Field.of(value);
            return this;
        }
        public Builder tabs(List<Tab> value) {
            this.tabs = value;
            this.tabsSet = true;
            return this;
        }
        public LivePane build() { return new LivePane(this); }
    }
}
