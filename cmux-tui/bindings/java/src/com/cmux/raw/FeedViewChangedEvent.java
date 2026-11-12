// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable feed-view-changed event. Protocol v12; streams: subscribe. */
public final class FeedViewChangedEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final List<String> changed;
    private final UInt64 revision;

    private FeedViewChangedEvent(Builder builder) {
        if (!builder.changedSet) throw new IllegalArgumentException("changed is required");
        this.changed = List.copyOf(Wire.nonNull(builder.changed, "changed"));
        if (!builder.revisionSet) throw new IllegalArgumentException("revision is required");
        this.revision = Wire.nonNull(builder.revision, "revision");
    }

    public static Builder builder() { return new Builder(); }

    public List<String> changed() { return changed; }
    public UInt64 revision() { return revision; }
    @Override public String event() { return "feed-view-changed"; }

    public static FeedViewChangedEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FeedViewChangedEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "feed-view-changed", "FeedViewChangedEvent.event");
        Object rawChanged = Wire.required(object, "changed");
        builder.changed(Wire.array(rawChanged, "FeedViewChangedEvent.changed", item -> Wire.string(item, "FeedViewChangedEvent.changed item")));
        Object rawRevision = Wire.required(object, "revision");
        builder.revision(Wire.uint64(rawRevision, "FeedViewChangedEvent.revision"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "feed-view-changed");
        Wire.put(object, "changed", changed);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FeedViewChangedEvent that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, revision); }

    @Override
    public String toString() { return "FeedViewChangedEvent" + toWire(); }

    public static final class Builder {
        private List<String> changed;
        private boolean changedSet;
        private UInt64 revision;
        private boolean revisionSet;

        public Builder changed(List<String> value) {
            this.changed = value;
            this.changedSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = value;
            this.revisionSet = true;
            return this;
        }
        public FeedViewChangedEvent build() { return new FeedViewChangedEvent(this); }
    }
}
