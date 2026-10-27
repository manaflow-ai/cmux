// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppGrant implements WireValue {
    private final boolean granted;
    private final String scope;

    private AppGrant(Builder builder) {
        if (!builder.grantedSet) throw new IllegalArgumentException("granted is required");
        this.granted = builder.granted;
        if (!builder.scopeSet) throw new IllegalArgumentException("scope is required");
        this.scope = Wire.nonNull(builder.scope, "scope");
    }

    public static Builder builder() { return new Builder(); }

    public boolean granted() { return granted; }
    public String scope() { return scope; }

    public static AppGrant fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppGrant");
        Builder builder = builder();
        Object rawGranted = Wire.required(object, "granted");
        builder.granted(Wire.bool(rawGranted, "AppGrant.granted"));
        Object rawScope = Wire.required(object, "scope");
        builder.scope(Wire.string(rawScope, "AppGrant.scope"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "granted", granted);
        Wire.put(object, "scope", scope);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppGrant that)) return false;
        return Objects.equals(granted, that.granted) && Objects.equals(scope, that.scope);
    }

    @Override
    public int hashCode() { return Objects.hash(granted, scope); }

    @Override
    public String toString() { return "AppGrant" + toWire(); }

    public static final class Builder {
        private Boolean granted;
        private boolean grantedSet;
        private String scope;
        private boolean scopeSet;

        public Builder granted(boolean value) {
            this.granted = value;
            this.grantedSet = true;
            return this;
        }
        public Builder scope(String value) {
            this.scope = value;
            this.scopeSet = true;
            return this;
        }
        public AppGrant build() { return new AppGrant(this); }
    }
}
