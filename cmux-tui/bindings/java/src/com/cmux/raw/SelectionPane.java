// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SelectionPane implements WireValue {
    private final UInt64 activeTab;
    private final UInt64 focusedAt;
    private final UInt64 id;

    private SelectionPane(Builder builder) {
        if (!builder.activeTabSet) throw new IllegalArgumentException("active_tab is required");
        this.activeTab = Wire.nonNull(builder.activeTab, "active_tab");
        if (!builder.focusedAtSet) throw new IllegalArgumentException("focused_at is required");
        this.focusedAt = Wire.nonNull(builder.focusedAt, "focused_at");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 activeTab() { return activeTab; }
    public UInt64 focusedAt() { return focusedAt; }
    public UInt64 id() { return id; }

    public static SelectionPane fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SelectionPane");
        Builder builder = builder();
        Object rawActiveTab = Wire.required(object, "active_tab");
        builder.activeTab(Wire.uint64(rawActiveTab, "SelectionPane.active_tab"));
        Object rawFocusedAt = Wire.required(object, "focused_at");
        builder.focusedAt(Wire.uint64(rawFocusedAt, "SelectionPane.focused_at"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "SelectionPane.id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "active_tab", activeTab);
        Wire.put(object, "focused_at", focusedAt);
        Wire.put(object, "id", id);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SelectionPane that)) return false;
        return Objects.equals(activeTab, that.activeTab) && Objects.equals(focusedAt, that.focusedAt) && Objects.equals(id, that.id);
    }

    @Override
    public int hashCode() { return Objects.hash(activeTab, focusedAt, id); }

    @Override
    public String toString() { return "SelectionPane" + toWire(); }

    public static final class Builder {
        private UInt64 activeTab;
        private boolean activeTabSet;
        private UInt64 focusedAt;
        private boolean focusedAtSet;
        private UInt64 id;
        private boolean idSet;

        public Builder activeTab(UInt64 value) {
            this.activeTab = value;
            this.activeTabSet = true;
            return this;
        }
        public Builder focusedAt(UInt64 value) {
            this.focusedAt = value;
            this.focusedAtSet = true;
            return this;
        }
        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public SelectionPane build() { return new SelectionPane(this); }
    }
}
