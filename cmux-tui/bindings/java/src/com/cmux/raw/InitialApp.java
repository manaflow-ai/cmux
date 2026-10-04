// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class InitialApp implements WireValue {
    private final String app;
    private final Field<String> route;

    private InitialApp(Builder builder) {
        if (!builder.appSet) throw new IllegalArgumentException("app is required");
        this.app = Wire.nonNull(builder.app, "app");
        this.route = builder.route;
    }

    public static Builder builder() { return new Builder(); }

    public String app() { return app; }
    public Field<String> route() { return route; }

    public static InitialApp fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "InitialApp");
        Builder builder = builder();
        Object rawApp = Wire.required(object, "app");
        builder.app(Wire.string(rawApp, "InitialApp.app"));
        Object rawRoute = Wire.optional(object, "route");
        if (!Wire.isMissing(rawRoute)) {
            builder.route(rawRoute == null ? null : Wire.string(rawRoute, "InitialApp.route"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "app", app);
        Wire.put(object, "route", route);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof InitialApp that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(route, that.route);
    }

    @Override
    public int hashCode() { return Objects.hash(app, route); }

    @Override
    public String toString() { return "InitialApp" + toWire(); }

    public static final class Builder {
        private String app;
        private boolean appSet;
        private Field<String> route = Field.omitted();

        public Builder app(String value) {
            this.app = value;
            this.appSet = true;
            return this;
        }
        public Builder route(String value) {
            this.route = Field.ofNullable(value);
            return this;
        }
        public InitialApp build() { return new InitialApp(this); }
    }
}
