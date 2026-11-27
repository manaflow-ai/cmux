// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SnapshotRequestResult implements WireValue {
    private final Field<String> reason;
    private final Field<String> requestId;
    private final Field<UInt64> retryAfterMs;
    private final SnapshotRequestResultStatus status;
    private final UInt64 surface;

    private SnapshotRequestResult(Builder builder) {
        this.reason = builder.reason;
        this.requestId = builder.requestId;
        this.retryAfterMs = builder.retryAfterMs;
        if (!builder.statusSet) throw new IllegalArgumentException("status is required");
        this.status = Wire.nonNull(builder.status, "status");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> reason() { return reason; }
    public Field<String> requestId() { return requestId; }
    public Field<UInt64> retryAfterMs() { return retryAfterMs; }
    public SnapshotRequestResultStatus status() { return status; }
    public UInt64 surface() { return surface; }

    public static SnapshotRequestResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SnapshotRequestResult");
        Builder builder = builder();
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : Wire.string(rawReason, "SnapshotRequestResult.reason"));
        }
        Object rawRequestId = Wire.optional(object, "request_id");
        if (!Wire.isMissing(rawRequestId)) {
            builder.requestId(rawRequestId == null ? null : Wire.string(rawRequestId, "SnapshotRequestResult.request_id"));
        }
        Object rawRetryAfterMs = Wire.optional(object, "retry_after_ms");
        if (!Wire.isMissing(rawRetryAfterMs)) {
            builder.retryAfterMs(rawRetryAfterMs == null ? null : Wire.uint64(rawRetryAfterMs, "SnapshotRequestResult.retry_after_ms"));
        }
        Object rawStatus = Wire.required(object, "status");
        builder.status(SnapshotRequestResultStatus.fromWire(rawStatus));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "SnapshotRequestResult.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "reason", reason);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "retry_after_ms", retryAfterMs);
        Wire.put(object, "status", status);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SnapshotRequestResult that)) return false;
        return Objects.equals(reason, that.reason) && Objects.equals(requestId, that.requestId) && Objects.equals(retryAfterMs, that.retryAfterMs) && Objects.equals(status, that.status) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(reason, requestId, retryAfterMs, status, surface); }

    @Override
    public String toString() { return "SnapshotRequestResult" + toWire(); }

    public static final class Builder {
        private Field<String> reason = Field.omitted();
        private Field<String> requestId = Field.omitted();
        private Field<UInt64> retryAfterMs = Field.omitted();
        private SnapshotRequestResultStatus status;
        private boolean statusSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder reason(String value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder requestId(String value) {
            this.requestId = Field.ofNullable(value);
            return this;
        }
        public Builder retryAfterMs(UInt64 value) {
            this.retryAfterMs = Field.ofNullable(value);
            return this;
        }
        public Builder status(SnapshotRequestResultStatus value) {
            this.status = value;
            this.statusSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public SnapshotRequestResult build() { return new SnapshotRequestResult(this); }
    }
}
