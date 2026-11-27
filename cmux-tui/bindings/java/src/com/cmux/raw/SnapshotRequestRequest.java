// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable snapshot-request request. Protocol v12; authority: frontend. */
public final class SnapshotRequestRequest implements WireValue {
    private final Field<SnapshotRequestHave> have;
    private final Field<String> reason;
    private final Field<String> requestId;
    private final UInt64 surface;

    private SnapshotRequestRequest(Builder builder) {
        this.have = builder.have;
        this.reason = builder.reason;
        this.requestId = builder.requestId;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<SnapshotRequestHave> have() { return have; }
    public Field<String> reason() { return reason; }
    public Field<String> requestId() { return requestId; }
    public UInt64 surface() { return surface; }

    public static SnapshotRequestRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SnapshotRequestRequest");
        Builder builder = builder();
        Object rawHave = Wire.optional(object, "have");
        if (!Wire.isMissing(rawHave)) {
            builder.have(rawHave == null ? null : SnapshotRequestHave.fromWire(rawHave));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : Wire.string(rawReason, "SnapshotRequestRequest.reason"));
        }
        Object rawRequestId = Wire.optional(object, "request_id");
        if (!Wire.isMissing(rawRequestId)) {
            builder.requestId(rawRequestId == null ? null : Wire.string(rawRequestId, "SnapshotRequestRequest.request_id"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SnapshotRequestRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "have", have);
        Wire.put(object, "reason", reason);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SnapshotRequestRequest that)) return false;
        return Objects.equals(have, that.have) && Objects.equals(reason, that.reason) && Objects.equals(requestId, that.requestId) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(have, reason, requestId, surface); }

    @Override
    public String toString() { return "SnapshotRequestRequest" + toWire(); }

    public static final class Builder {
        private Field<SnapshotRequestHave> have = Field.omitted();
        private Field<String> reason = Field.omitted();
        private Field<String> requestId = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder have(SnapshotRequestHave value) {
            this.have = Field.ofNullable(value);
            return this;
        }
        public Builder reason(String value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SnapshotRequestRequest build() { return new SnapshotRequestRequest(this); }
    }
}
