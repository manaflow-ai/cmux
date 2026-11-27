// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable screen-changed event. Protocol v12; streams: subscribe-deltas. */
public final class ScreenChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Screen entity;
    private final Field<UInt64> index;
    private final UInt64 screen;
    private final UInt64 workspace;

    private ScreenChangedEvent(Builder builder) {
        if (!builder.entitySet) throw new IllegalArgumentException("entity is required");
        this.entity = Wire.nonNull(builder.entity, "entity");
        this.index = builder.index;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public Screen entity() { return entity; }
    public Field<UInt64> index() { return index; }
    public UInt64 screen() { return screen; }
    public UInt64 workspace() { return workspace; }
    @Override public String event() { return "screen-changed"; }

    public static ScreenChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScreenChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "screen-changed", "ScreenChangedEvent.event");
        Object rawEntity = Wire.required(object, "entity");
        builder.entity(Screen.fromWire(rawEntity));
        Object rawIndex = Wire.optional(object, "index");
        if (!Wire.isMissing(rawIndex)) {
            builder.index(rawIndex == null ? null : Wire.uint64(rawIndex, "ScreenChangedEvent.index"));
        }
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "ScreenChangedEvent.screen"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "ScreenChangedEvent.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "screen-changed");
        Wire.put(object, "entity", entity);
        Wire.put(object, "index", index);
        Wire.put(object, "screen", screen);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScreenChangedEvent that)) return false;
        return Objects.equals(entity, that.entity) && Objects.equals(index, that.index) && Objects.equals(screen, that.screen) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(entity, index, screen, workspace); }

    @Override
    public String toString() { return "ScreenChangedEvent" + toWire(); }

    public static final class Builder {
        private Screen entity;
        private boolean entitySet;
        private Field<UInt64> index = Field.omitted();
        private UInt64 screen;
        private boolean screenSet;
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder entity(Screen value) {
            this.entity = value;
            this.entitySet = true;
            return this;
        }
        public Builder index(UInt64 value) {
            this.index = Field.ofNullable(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = value;
            this.workspaceSet = true;
            return this;
        }
        public ScreenChangedEvent build() { return new ScreenChangedEvent(this); }
    }
}
