// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable layout-changed event. Protocol v6; streams: subscribe. */
public final class LayoutChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<UInt64> activePane;
    /** What set the event off, for a connection that echoed event-cause-v1 in set-client-info: frontend for a request of the verified app, automation for any other request; absent when the daemon or a program set it off on its own. A scheduling hint only; it grants nothing. */
    private final Field<EventCause> cause;
    private final Field<Layout> layout;
    private final UInt64 screen;
    private final Field<String> transaction;
    private final Field<UInt64> workspace;
    private final Field<UInt64> zoomedPane;

    private LayoutChangedEvent(Builder builder) {
        this.activePane = builder.activePane;
        this.cause = builder.cause;
        this.layout = builder.layout;
        if (!builder.screenSet) throw new IllegalArgumentException("screen is required");
        this.screen = Wire.nonNull(builder.screen, "screen");
        this.transaction = builder.transaction;
        this.workspace = builder.workspace;
        this.zoomedPane = builder.zoomedPane;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> activePane() { return activePane; }
    public Field<EventCause> cause() { return cause; }
    public Field<Layout> layout() { return layout; }
    public UInt64 screen() { return screen; }
    public Field<String> transaction() { return transaction; }
    public Field<UInt64> workspace() { return workspace; }
    public Field<UInt64> zoomedPane() { return zoomedPane; }
    @Override public String event() { return "layout-changed"; }

    public static LayoutChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "layout-changed", "LayoutChangedEvent.event");
        Object rawActivePane = Wire.optional(object, "active_pane");
        if (!Wire.isMissing(rawActivePane)) {
            builder.activePane(Wire.uint64(rawActivePane, "LayoutChangedEvent.active_pane"));
        }
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(EventCause.fromWire(rawCause));
        }
        Object rawLayout = Wire.optional(object, "layout");
        if (!Wire.isMissing(rawLayout)) {
            builder.layout(Layout.fromWire(rawLayout));
        }
        Object rawScreen = Wire.required(object, "screen");
        builder.screen(Wire.uint64(rawScreen, "LayoutChangedEvent.screen"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(Wire.string(rawTransaction, "LayoutChangedEvent.transaction"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(Wire.uint64(rawWorkspace, "LayoutChangedEvent.workspace"));
        }
        Object rawZoomedPane = Wire.optional(object, "zoomed_pane");
        if (!Wire.isMissing(rawZoomedPane)) {
            builder.zoomedPane(rawZoomedPane == null ? null : Wire.uint64(rawZoomedPane, "LayoutChangedEvent.zoomed_pane"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "layout-changed");
        Wire.put(object, "active_pane", activePane);
        Wire.put(object, "cause", cause);
        Wire.put(object, "layout", layout);
        Wire.put(object, "screen", screen);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "workspace", workspace);
        Wire.put(object, "zoomed_pane", zoomedPane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutChangedEvent that)) return false;
        return Objects.equals(activePane, that.activePane) && Objects.equals(cause, that.cause) && Objects.equals(layout, that.layout) && Objects.equals(screen, that.screen) && Objects.equals(transaction, that.transaction) && Objects.equals(workspace, that.workspace) && Objects.equals(zoomedPane, that.zoomedPane);
    }

    @Override
    public int hashCode() { return Objects.hash(activePane, cause, layout, screen, transaction, workspace, zoomedPane); }

    @Override
    public String toString() { return "LayoutChangedEvent" + toWire(); }

    public static final class Builder {
        private Field<UInt64> activePane = Field.omitted();
        private Field<EventCause> cause = Field.omitted();
        private Field<Layout> layout = Field.omitted();
        private UInt64 screen;
        private boolean screenSet;
        private Field<String> transaction = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();
        private Field<UInt64> zoomedPane = Field.omitted();

        public Builder activePane(UInt64 value) {
            this.activePane = Field.of(value);
            return this;
        }
        public Builder cause(EventCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder layout(Layout value) {
            this.layout = Field.of(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = value;
            this.screenSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.of(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.of(value);
            return this;
        }
        public Builder zoomedPane(UInt64 value) {
            this.zoomedPane = Field.ofNullable(value);
            return this;
        }
        public LayoutChangedEvent build() { return new LayoutChangedEvent(this); }
    }
}
