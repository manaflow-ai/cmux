// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable feed-reports-changed event. Protocol v12; streams: subscribe. */
public final class FeedReportsChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final UInt64 revision;

    private FeedReportsChangedEvent(Builder builder) {
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 revision() { return revision; }
    @Override public String event() { return "feed-reports-changed"; }

    public static FeedReportsChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FeedReportsChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "feed-reports-changed", "FeedReportsChangedEvent.event");
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "FeedReportsChangedEvent.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "feed-reports-changed");
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FeedReportsChangedEvent that)) return false;
        return Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(revision); }

    @Override
    public String toString() { return "FeedReportsChangedEvent" + toWire(); }

    public static final class Builder {
        private UInt64 revision;
        private boolean revisionSet;

        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public FeedReportsChangedEvent build() { return new FeedReportsChangedEvent(this); }
    }
}
