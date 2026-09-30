// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable detached event. Protocol v5; streams: attach-byte, attach-render, attach-browser. */
public final class DetachedEvent implements WireValue, BrowserAttachEvent, ByteAttachEvent, ProtocolEvent, RenderAttachEvent {
    private final Field<SizeDetachActor> by;
    private final Field<DetachReason> reason;
    private final UInt64 surface;
    private final Field<String> view;

    private DetachedEvent(Builder builder) {
        this.by = builder.by;
        this.reason = builder.reason;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.view = builder.view;
    }

    public static Builder builder() { return new Builder(); }

    public Field<SizeDetachActor> by() { return by; }
    public Field<DetachReason> reason() { return reason; }
    public UInt64 surface() { return surface; }
    public Field<String> view() { return view; }
    @Override public String event() { return "detached"; }

    public static DetachedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DetachedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "detached", "DetachedEvent.event");
        Object rawBy = Wire.optional(object, "by");
        if (!Wire.isMissing(rawBy)) {
            builder.by(SizeDetachActor.fromWire(rawBy));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(DetachReason.fromWire(rawReason));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "DetachedEvent.surface"));
        Object rawView = Wire.optional(object, "view");
        if (!Wire.isMissing(rawView)) {
            builder.view(Wire.string(rawView, "DetachedEvent.view"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "detached");
        Wire.put(object, "by", by);
        Wire.put(object, "reason", reason);
        Wire.put(object, "surface", surface);
        Wire.put(object, "view", view);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DetachedEvent that)) return false;
        return Objects.equals(by, that.by) && Objects.equals(reason, that.reason) && Objects.equals(surface, that.surface) && Objects.equals(view, that.view);
    }

    @Override
    public int hashCode() { return Objects.hash(by, reason, surface, view); }

    @Override
    public String toString() { return "DetachedEvent" + toWire(); }

    public static final class Builder {
        private Field<SizeDetachActor> by = Field.omitted();
        private Field<DetachReason> reason = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> view = Field.omitted();

        public Builder by(SizeDetachActor value) {
            this.by = Field.of(value);
            return this;
        }
        public Builder reason(DetachReason value) {
            this.reason = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder view(String value) {
            this.view = Field.of(value);
            return this;
        }
        public DetachedEvent build() { return new DetachedEvent(this); }
    }
}
