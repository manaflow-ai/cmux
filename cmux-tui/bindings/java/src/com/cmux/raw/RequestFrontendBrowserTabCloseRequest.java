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
    private final Field<CloseReason> reason;
    private final UInt64 surface;

    private RequestFrontendBrowserTabCloseRequest(Builder builder) {
        this.reason = builder.reason;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<CloseReason> reason() { return reason; }
    public UInt64 surface() { return surface; }

    public static RequestFrontendBrowserTabCloseRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RequestFrontendBrowserTabCloseRequest");
        Builder builder = builder();
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
        Wire.put(object, "reason", reason);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RequestFrontendBrowserTabCloseRequest that)) return false;
        return Objects.equals(reason, that.reason) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(reason, surface); }

    @Override
    public String toString() { return "RequestFrontendBrowserTabCloseRequest" + toWire(); }

    public static final class Builder {
        private Field<CloseReason> reason = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;

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
