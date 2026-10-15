// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable report-frontend-browser-tab-removed request. Protocol v12; authority: control. */
public final class ReportFrontendBrowserTabRemovedRequest implements WireValue {
    private final Field<String> mutationId;
    private final Field<String> origin;
    /** answered: the owner closed it for a close request; user_closed: the user closed it in the app; page_closed: the page closed itself; extension: an extension removed it. */
    private final ReportFrontendBrowserTabRemovedRequestReason reason;
    /** The close request this removal answers, if any. */
    private final Field<String> requestId;
    private final UInt64 surface;

    private ReportFrontendBrowserTabRemovedRequest(Builder builder) {
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
        this.requestId = builder.requestId;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public ReportFrontendBrowserTabRemovedRequestReason reason() { return reason; }
    public Field<String> requestId() { return requestId; }
    public UInt64 surface() { return surface; }

    public static ReportFrontendBrowserTabRemovedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReportFrontendBrowserTabRemovedRequest");
        Builder builder = builder();
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "ReportFrontendBrowserTabRemovedRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "ReportFrontendBrowserTabRemovedRequest.origin"));
        }
        Object rawReason = Wire.required(object, "reason");
        builder.reason(ReportFrontendBrowserTabRemovedRequestReason.fromWire(rawReason));
        Object rawRequestId = Wire.optional(object, "request_id");
        if (!Wire.isMissing(rawRequestId)) {
            builder.requestId(rawRequestId == null ? null : Wire.string(rawRequestId, "ReportFrontendBrowserTabRemovedRequest.request_id"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ReportFrontendBrowserTabRemovedRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "reason", reason);
        Wire.put(object, "request_id", requestId);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReportFrontendBrowserTabRemovedRequest that)) return false;
        return Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(reason, that.reason) && Objects.equals(requestId, that.requestId) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(mutationId, origin, reason, requestId, surface); }

    @Override
    public String toString() { return "ReportFrontendBrowserTabRemovedRequest" + toWire(); }

    public static final class Builder {
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private ReportFrontendBrowserTabRemovedRequestReason reason;
        private boolean reasonSet;
        private Field<String> requestId = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder reason(ReportFrontendBrowserTabRemovedRequestReason value) {
            this.reason = value;
            this.reasonSet = true;
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
        public ReportFrontendBrowserTabRemovedRequest build() { return new ReportFrontendBrowserTabRemovedRequest(this); }
    }
}
