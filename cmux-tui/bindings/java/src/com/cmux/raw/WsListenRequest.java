// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable ws-listen request. Protocol v12; authority: local-admin. */
public final class WsListenRequest implements WireValue {
    private final Field<String> allowOrigin;

    private WsListenRequest(Builder builder) {
        this.allowOrigin = builder.allowOrigin;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> allowOrigin() { return allowOrigin; }

    public static WsListenRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "WsListenRequest");
        Builder builder = builder();
        Object rawAllowOrigin = Wire.optional(object, "allow_origin");
        if (!Wire.isMissing(rawAllowOrigin)) {
            builder.allowOrigin(rawAllowOrigin == null ? null : Wire.string(rawAllowOrigin, "WsListenRequest.allow_origin"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "allow_origin", allowOrigin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof WsListenRequest that)) return false;
        return Objects.equals(allowOrigin, that.allowOrigin);
    }

    @Override
    public int hashCode() { return Objects.hash(allowOrigin); }

    @Override
    public String toString() { return "WsListenRequest" + toWire(); }

    public static final class Builder {
        private Field<String> allowOrigin = Field.omitted();

        public Builder allowOrigin(String value) {
            this.allowOrigin = Field.ofNullable(value);
            return this;
        }
        public WsListenRequest build() { return new WsListenRequest(this); }
    }
}
