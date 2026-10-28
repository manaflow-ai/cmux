// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-terminal-links request. Protocol v12; authority: local-admin. */
public final class AppsTerminalLinksRequest implements WireValue {
    private final Field<AppOrigin> origin;

    private AppsTerminalLinksRequest(Builder builder) {
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public Field<AppOrigin> origin() { return origin; }

    public static AppsTerminalLinksRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsTerminalLinksRequest");
        Builder builder = builder();
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsTerminalLinksRequest that)) return false;
        return Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(origin); }

    @Override
    public String toString() { return "AppsTerminalLinksRequest" + toWire(); }

    public static final class Builder {
        private Field<AppOrigin> origin = Field.omitted();

        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public AppsTerminalLinksRequest build() { return new AppsTerminalLinksRequest(this); }
    }
}
