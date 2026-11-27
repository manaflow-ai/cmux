// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable delete-profile request. Protocol v12; authority: control. */
public final class DeleteProfileRequest implements WireValue {
    private final Field<String> moveTo;
    private final String profile;

    private DeleteProfileRequest(Builder builder) {
        this.moveTo = builder.moveTo;
        if (!builder.profileSet) throw new IllegalArgumentException("profile is required");
        this.profile = Wire.nonNull(builder.profile, "profile");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> moveTo() { return moveTo; }
    public String profile() { return profile; }

    public static DeleteProfileRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeleteProfileRequest");
        Builder builder = builder();
        Object rawMoveTo = Wire.optional(object, "move_to");
        if (!Wire.isMissing(rawMoveTo)) {
            builder.moveTo(rawMoveTo == null ? null : Wire.string(rawMoveTo, "DeleteProfileRequest.move_to"));
        }
        Object rawProfile = Wire.required(object, "profile");
        builder.profile(Wire.string(rawProfile, "DeleteProfileRequest.profile"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "move_to", moveTo);
        Wire.put(object, "profile", profile);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeleteProfileRequest that)) return false;
        return Objects.equals(moveTo, that.moveTo) && Objects.equals(profile, that.profile);
    }

    @Override
    public int hashCode() { return Objects.hash(moveTo, profile); }

    @Override
    public String toString() { return "DeleteProfileRequest" + toWire(); }

    public static final class Builder {
        private Field<String> moveTo = Field.omitted();
        private String profile;
        private boolean profileSet;

        public Builder moveTo(String value) {
            this.moveTo = Field.ofNullable(value);
            return this;
        }
        public Builder profile(String value) {
            this.profile = value;
            this.profileSet = true;
            return this;
        }
        public DeleteProfileRequest build() { return new DeleteProfileRequest(this); }
    }
}
