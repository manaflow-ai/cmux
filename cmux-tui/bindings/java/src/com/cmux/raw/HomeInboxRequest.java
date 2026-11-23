// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable home-inbox request. Protocol v12; authority: local-admin. */
public final class HomeInboxRequest implements WireValue {
    private final Field<List<String>> owners;
    private final Field<UInt64> since;

    private HomeInboxRequest(Builder builder) {
        this.owners = builder.owners.map(value -> List.copyOf(value));
        this.since = builder.since;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> owners() { return owners; }
    public Field<UInt64> since() { return since; }

    public static HomeInboxRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HomeInboxRequest");
        Builder builder = builder();
        Object rawOwners = Wire.optional(object, "owners");
        if (!Wire.isMissing(rawOwners)) {
            builder.owners(rawOwners == null ? null : Wire.array(rawOwners, "HomeInboxRequest.owners", item -> Wire.string(item, "HomeInboxRequest.owners item")));
        }
        Object rawSince = Wire.optional(object, "since");
        if (!Wire.isMissing(rawSince)) {
            builder.since(rawSince == null ? null : Wire.uint64(rawSince, "HomeInboxRequest.since"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "owners", owners);
        Wire.put(object, "since", since);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HomeInboxRequest that)) return false;
        return Objects.equals(owners, that.owners) && Objects.equals(since, that.since);
    }

    @Override
    public int hashCode() { return Objects.hash(owners, since); }

    @Override
    public String toString() { return "HomeInboxRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> owners = Field.omitted();
        private Field<UInt64> since = Field.omitted();

        public Builder owners(List<String> value) {
            this.owners = Field.ofNullable(value);
            return this;
        }
        public Builder since(UInt64 value) {
            this.since = Field.ofNullable(value);
            return this;
        }
        public HomeInboxRequest build() { return new HomeInboxRequest(this); }
    }
}
