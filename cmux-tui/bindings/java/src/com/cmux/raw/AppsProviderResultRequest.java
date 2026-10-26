// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-provider-result request. Protocol v12; authority: local-admin. */
public final class AppsProviderResultRequest implements WireValue {
    private final Field<Object> body;
    private final boolean ok;
    private final Field<AppOrigin> origin;
    private final UInt64 requestId;

    private AppsProviderResultRequest(Builder builder) {
        this.body = builder.body.map(value -> Wire.immutableJson(value));
        if (!builder.okSet) throw new IllegalArgumentException("ok is required");
        this.ok = builder.ok;
        this.origin = builder.origin;
        if (!builder.requestIdSet) throw new IllegalArgumentException("request_id is required");
        this.requestId = Wire.nonNull(builder.requestId, "request_id");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Object> body() { return body; }
    public boolean ok() { return ok; }
    public Field<AppOrigin> origin() { return origin; }
    public UInt64 requestId() { return requestId; }

    public static AppsProviderResultRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsProviderResultRequest");
        Builder builder = builder();
        Object rawBody = Wire.optional(object, "body");
        if (!Wire.isMissing(rawBody)) {
            builder.body(rawBody == null ? null : Wire.immutableJson(rawBody));
        }
        Object rawOk = Wire.required(object, "ok");
        builder.ok(Wire.bool(rawOk, "AppsProviderResultRequest.ok"));
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        Object rawRequestId = Wire.required(object, "request_id");
        builder.requestId(Wire.uint64(rawRequestId, "AppsProviderResultRequest.request_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "body", body);
        Wire.put(object, "ok", ok);
        Wire.put(object, "origin", origin);
        Wire.put(object, "request_id", requestId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsProviderResultRequest that)) return false;
        return Objects.equals(body, that.body) && Objects.equals(ok, that.ok) && Objects.equals(origin, that.origin) && Objects.equals(requestId, that.requestId);
    }

    @Override
    public int hashCode() { return Objects.hash(body, ok, origin, requestId); }

    @Override
    public String toString() { return "AppsProviderResultRequest" + toWire(); }

    public static final class Builder {
        private Field<Object> body = Field.omitted();
        private Boolean ok;
        private boolean okSet;
        private Field<AppOrigin> origin = Field.omitted();
        private UInt64 requestId;
        private boolean requestIdSet;

        public Builder body(Object value) {
            this.body = Field.ofNullable(value);
            return this;
        }
        public Builder ok(boolean value) {
            this.ok = value;
            this.okSet = true;
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public Builder requestId(UInt64 value) {
            this.requestId = value;
            this.requestIdSet = true;
            return this;
        }
        public AppsProviderResultRequest build() { return new AppsProviderResultRequest(this); }
    }
}
