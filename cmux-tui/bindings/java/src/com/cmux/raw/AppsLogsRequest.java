// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable apps-logs request. Protocol v12; authority: local-admin. */
public final class AppsLogsRequest implements WireValue {
    private final String app;
    private final Field<Boolean> follow;
    private final Field<AppOrigin> origin;

    private AppsLogsRequest(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = Wire.nonNull(builder.app, "app");
        this.follow = builder.follow;
        this.origin = builder.origin;
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return app; }
    public Field<Boolean> follow() { return follow; }
    public Field<AppOrigin> origin() { return origin; }

    public static AppsLogsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppsLogsRequest");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.string(rawApp, "AppsLogsRequest.app"));
        Object rawFollow = Wire.optional(object, "follow");
        if (!Wire.isMissing(rawFollow)) {
            builder.follow(Wire.bool(rawFollow, "AppsLogsRequest.follow"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(AppOrigin.fromWire(rawOrigin));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "follow", follow);
        Wire.put(object, "origin", origin);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppsLogsRequest that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(follow, that.follow) && Objects.equals(origin, that.origin);
    }

    @Override
    public int hashCode() { return Objects.hash(app, follow, origin); }

    @Override
    public String toString() { return "AppsLogsRequest" + toWire(); }

    public static final class Builder {
        private String app;
        private boolean appSet;
        private Field<Boolean> follow = Field.omitted();
        private Field<AppOrigin> origin = Field.omitted();

        public Builder app(String value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder follow(Boolean value) {
            this.follow = Field.of(value);
            return this;
        }
        public Builder origin(AppOrigin value) {
            this.origin = Field.of(value);
            return this;
        }
        public AppsLogsRequest build() { return new AppsLogsRequest(this); }
    }
}
