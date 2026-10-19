// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable request-frontend-browser-tab-close request. Protocol v12; authority: control. */
public final class RequestFrontendBrowserTabCloseRequest implements WireValue {
    /** How long the owner may take to answer, 1-30000 ms. With no answer by then the request settles timed_out and the owner must close the tab without a beforeunload veto. A request that joins an open one keeps that request's deadline. */
    private final Field<UInt64> deadlineMs;
    private final Field<CloseReason> reason;
    private final UInt64 surface;

    private RequestFrontendBrowserTabCloseRequest(Builder builder) {
        this.deadlineMs = builder.deadlineMs;
        this.reason = builder.reason;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> deadlineMs() { return deadlineMs; }
    public Field<CloseReason> reason() { return reason; }
    public UInt64 surface() { return surface; }

    public static RequestFrontendBrowserTabCloseRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RequestFrontendBrowserTabCloseRequest");
        Builder builder = builder();
        Object rawDeadlineMs = Wire.optional(object, "deadline_ms");
        if (!Wire.isMissing(rawDeadlineMs)) {
            builder.deadlineMs(Wire.uint64(rawDeadlineMs, "RequestFrontendBrowserTabCloseRequest.deadline_ms"));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : CloseReason.fromWire(rawReason));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "RequestFrontendBrowserTabCloseRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "deadline_ms", deadlineMs);
        Wire.put(object, "reason", reason);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RequestFrontendBrowserTabCloseRequest that)) return false;
        return Objects.equals(deadlineMs, that.deadlineMs) && Objects.equals(reason, that.reason) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(deadlineMs, reason, surface); }

    @Override
    public String toString() { return "RequestFrontendBrowserTabCloseRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> deadlineMs = Field.omitted();
        private Field<CloseReason> reason = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder deadlineMs(UInt64 value) {
            this.deadlineMs = Field.of(value);
            return this;
        }
        public Builder reason(CloseReason value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public RequestFrontendBrowserTabCloseRequest build() { return new RequestFrontendBrowserTabCloseRequest(this); }
    }
}
