// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable screen-renamed event. Protocol v7; streams: subscribe-deltas. */
public final class ScreenRenamedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Screen entity;
    private final UInt64 screen;
    private final UInt64 workspace;

    private ScreenRenamedEvent(Builder builder) {
        if (!builder.entitySet) throw new IllegalArgumentException("entity is required");
        this.entity = Wire.nonNull(builder.entity, "entity");
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
        if (!builder.workspaceSet) throw new IllegalArgumentException("workspace is required");
        this.workspace = Wire.nonNull(builder.workspace, "workspace");
    }

    public static Builder builder() { return new Builder(); }

    public Screen entity() { return entity; }
    public UInt64 screen() { return screen; }
    public UInt64 workspace() { return workspace; }
    @Override public String event() { return "screen-renamed"; }

    public static ScreenRenamedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ScreenRenamedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "screen-renamed", "ScreenRenamedEvent.event");
        Object rawEntity = Wire.required(object, "entity");
        builder.entity(Screen.fromWire(rawEntity));
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "ScreenRenamedEvent.screen"));
        Object rawWorkspace = Wire.required(object, "workspace");
        builder.workspace(Wire.uint64(rawWorkspace, "ScreenRenamedEvent.workspace"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "screen-renamed");
        Wire.put(object, "entity", entity);
        Wire.put(object, "screen", screen);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ScreenRenamedEvent that)) return false;
        return Objects.equals(entity, that.entity) && Objects.equals(screen, that.screen) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(entity, screen, workspace); }

    @Override
    public String toString() { return "ScreenRenamedEvent" + toWire(); }

    public static final class Builder {
        private Screen entity;
        private boolean entitySet;
        private UInt64 screen;
        private boolean screenSet;
        private UInt64 workspace;
        private boolean workspaceSet;

        public Builder entity(Screen value) {
            this.entity = value;
            this.entitySet = true;
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
        public ScreenRenamedEvent build() { return new ScreenRenamedEvent(this); }
    }
}
