// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable tab-changed event. Protocol v12; streams: subscribe-deltas. */
public final class TabChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Tab entity;
    private final Field<UInt64> index;
    private final UInt64 pane;
    private final UInt64 screen;
    private final UInt64 surface;
    private final Field<String> transaction;
    private final UInt64 workspace;

    private TabChangedEvent(Builder builder) {
        if (!builder.entitySet) throw new IllegalArgumentException("entity is required");
        this.entity = Wire.nonNull(builder.entity, "entity");
        this.index = builder.index;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.transaction = builder.transaction;
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public Tab entity() { return entity; }
    public Field<UInt64> index() { return index; }
    public UInt64 pane() { return pane; }
    public UInt64 screen() { return screen; }
    public UInt64 surface() { return surface; }
    public Field<String> transaction() { return transaction; }
    public UInt64 workspace() { return workspace; }
    @Override public String event() { return "tab-changed"; }

    public static TabChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TabChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "tab-changed", "TabChangedEvent.event");
        Object rawEntity = Wire.required(object, "entity");
        builder.entity(Tab.fromWire(rawEntity));
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "TabChangedEvent.index"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "TabChangedEvent.pane"));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "TabChangedEvent.screen"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TabChangedEvent.surface"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "TabChangedEvent.transaction"));
        }
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "TabChangedEvent.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "tab-changed");
        Wire.put(object, "entity", entity);
        Wire.put(object, "index", index);
        Wire.put(object, "pane", pane);
        Wire.put(object, "screen", screen);
        Wire.put(object, "surface", surface);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TabChangedEvent that)) return false;
        return Objects.equals(entity, that.entity) && Objects.equals(index, that.index) && Objects.equals(pane, that.pane) && Objects.equals(screen, that.screen) && Objects.equals(surface, that.surface) && Objects.equals(transaction, that.transaction) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(entity, index, pane, screen, surface, transaction, workspace); }

    @Override
    public String toString() { return "TabChangedEvent" + toWire(); }

    public static final class Builder {
        private Tab entity;
        private boolean entitySet;
        private Field<UInt64> index = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 screen;
        private boolean screenSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> transaction = Field.omitted();
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder entity(Tab value) {
            this.entity = value;
            this.entitySet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public TabChangedEvent build() { return new TabChangedEvent(this); }
    }
}
