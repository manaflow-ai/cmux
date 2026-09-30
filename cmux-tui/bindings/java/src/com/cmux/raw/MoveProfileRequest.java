// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-profile request. Protocol v12; authority: control. */
public final class MoveProfileRequest implements WireValue {
    private final UInt64 index;
    private final String profile;

    private MoveProfileRequest(Builder builder) {
        if (!builder.indexSet) throw new IllegalArgumentException("index is required");
        this.index = Wire.nonNull(builder.index, "index");
        if (!builder.profileSet) throw new IllegalArgumentException("profile is required");
        this.profile = Wire.nonNull(builder.profile, "profile");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 index() { return index; }
    public String profile() { return profile; }

    public static MoveProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveProfileRequest");
        Builder builder = builder();
        Object rawIndex = Wire.required(object, "index");
        builder.index(Wire.uint64(rawIndex, "MoveProfileRequest.index"));
        Object rawProfile = Wire.required(object, "profile");
        builder.profile(Wire.string(rawProfile, "MoveProfileRequest.profile"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "index", index);
        Wire.put(object, "profile", profile);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveProfileRequest that)) return false;
        return Objects.equals(index, that.index) && Objects.equals(profile, that.profile);
    }

    @Override
    public int hashCode() { return Objects.hash(index, profile); }

    @Override
    public String toString() { return "MoveProfileRequest" + toWire(); }

    public static final class Builder {
        private UInt64 index;
        private boolean indexSet;
        private String profile;
        private boolean profileSet;

        public Builder index(UInt64 value) {
            this.index = value;
            this.indexSet = true;
            return this;
        }
        public Builder profile(String value) {
            this.profile = value;
            this.profileSet = true;
            return this;
        }
        public MoveProfileRequest build() { return new MoveProfileRequest(this); }
    }
}
