// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable mark-workspaces-provider-managed request. Protocol v9; authority: provider-authority. */
public final class MarkWorkspacesProviderManagedRequest implements WireValue {
    private final String authority;

    private MarkWorkspacesProviderManagedRequest(Builder builder) {
        if (!builder.authoritySet) throw new IllegalArgumentException("authority is required");
        this.authority = Wire.nonNull(builder.authority, "authority");
    }

    public static Builder builder() { return new Builder(); }

    public String authority() { return authority; }

    public static MarkWorkspacesProviderManagedRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MarkWorkspacesProviderManagedRequest");
        Builder builder = builder();
        Object rawAuthority = Wire.required(object, "authority");
        builder.authority(Wire.string(rawAuthority, "MarkWorkspacesProviderManagedRequest.authority"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "authority", authority);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MarkWorkspacesProviderManagedRequest that)) return false;
        return Objects.equals(authority, that.authority);
    }

    @Override
    public int hashCode() { return Objects.hash(authority); }

    @Override
    public String toString() { return "MarkWorkspacesProviderManagedRequest" + toWire(); }

    public static final class Builder {
        private String authority;
        private boolean authoritySet;

        public Builder authority(String value) {
            this.authority = value;
            this.authoritySet = true;
            return this;
        }
        public MarkWorkspacesProviderManagedRequest build() { return new MarkWorkspacesProviderManagedRequest(this); }
    }
}
