// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-appearance-background request. Protocol v12; authority: control. */
public final class SetAppearanceBackgroundRequest implements WireValue {
    private final Field<AppearanceBackgroundRequest> background;

    private SetAppearanceBackgroundRequest(Builder builder) {
        this.background = builder.background;
    }

    public static Builder builder() { return new Builder(); }

    public Field<AppearanceBackgroundRequest> background() { return background; }

    public static SetAppearanceBackgroundRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetAppearanceBackgroundRequest");
        Builder builder = builder();
        Object rawBackground = Wire.optional(object, "background");
        if (!Wire.isMissing(rawBackground)) {
            builder.background(rawBackground == null ? null : AppearanceBackgroundRequest.fromWire(rawBackground));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "background", background);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetAppearanceBackgroundRequest that)) return false;
        return Objects.equals(background, that.background);
    }

    @Override
    public int hashCode() { return Objects.hash(background); }

    @Override
    public String toString() { return "SetAppearanceBackgroundRequest" + toWire(); }

    public static final class Builder {
        private Field<AppearanceBackgroundRequest> background = Field.omitted();

        public Builder background(AppearanceBackgroundRequest value) {
            this.background = Field.ofNullable(value);
            return this;
        }
        public SetAppearanceBackgroundRequest build() { return new SetAppearanceBackgroundRequest(this); }
    }
}
