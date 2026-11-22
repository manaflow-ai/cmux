// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-size-counts request. Protocol v12; authority: control. */
public final class SetSizeCountsRequest implements WireValue {
    private final Field<UInt64> client;
    private final Field<Boolean> counts;
    private final Field<String> lease;
    private final Field<String> participant;
    private final UInt64 surface;
    private final Field<String> view;

    private SetSizeCountsRequest(Builder builder) {
        this.client = builder.client;
        this.counts = builder.counts;
        this.lease = builder.lease;
        this.participant = builder.participant;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.view = builder.view;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> client() { return client; }
    public Field<Boolean> counts() { return counts; }
    public Field<String> lease() { return lease; }
    public Field<String> participant() { return participant; }
    public UInt64 surface() { return surface; }
    public Field<String> view() { return view; }

    public static SetSizeCountsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetSizeCountsRequest");
        Builder builder = builder();
        Object rawClient = Wire.optional(object, "client");
        if (!Wire.isMissing(rawClient)) {
            builder.client(rawClient == null ? null : Wire.uint64(rawClient, "SetSizeCountsRequest.client"));
        }
        Object rawCounts = Wire.optional(object, "counts");
        if (!Wire.isMissing(rawCounts)) {
            builder.counts(rawCounts == null ? null : Wire.bool(rawCounts, "SetSizeCountsRequest.counts"));
        }
        Object rawLease = Wire.optional(object, "lease");
        if (!Wire.isMissing(rawLease)) {
            builder.lease(rawLease == null ? null : Wire.string(rawLease, "SetSizeCountsRequest.lease"));
        }
        Object rawParticipant = Wire.optional(object, "participant");
        if (!Wire.isMissing(rawParticipant)) {
            builder.participant(rawParticipant == null ? null : Wire.string(rawParticipant, "SetSizeCountsRequest.participant"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SetSizeCountsRequest.surface"));
        Object rawView = Wire.optional(object, "view");
        if (!Wire.isMissing(rawView)) {
            builder.view(rawView == null ? null : Wire.string(rawView, "SetSizeCountsRequest.view"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "client", client);
        Wire.put(object, "counts", counts);
        Wire.put(object, "lease", lease);
        Wire.put(object, "participant", participant);
        Wire.put(object, "surface", surface);
        Wire.put(object, "view", view);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetSizeCountsRequest that)) return false;
        return Objects.equals(client, that.client) && Objects.equals(counts, that.counts) && Objects.equals(lease, that.lease) && Objects.equals(participant, that.participant) && Objects.equals(surface, that.surface) && Objects.equals(view, that.view);
    }

    @Override
    public int hashCode() { return Objects.hash(client, counts, lease, participant, surface, view); }

    @Override
    public String toString() { return "SetSizeCountsRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> client = Field.omitted();
        private Field<Boolean> counts = Field.omitted();
        private Field<String> lease = Field.omitted();
        private Field<String> participant = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> view = Field.omitted();

        public Builder client(UInt64 value) {
            this.client = Field.ofNullable(value);
            return this;
        }
        public Builder counts(Boolean value) {
            this.counts = Field.ofNullable(value);
            return this;
        }
        public Builder lease(String value) {
            this.lease = Field.ofNullable(value);
            return this;
        }
        public Builder participant(String value) {
            this.participant = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder view(String value) {
            this.view = Field.ofNullable(value);
            return this;
        }
        public SetSizeCountsRequest build() { return new SetSizeCountsRequest(this); }
    }
}
