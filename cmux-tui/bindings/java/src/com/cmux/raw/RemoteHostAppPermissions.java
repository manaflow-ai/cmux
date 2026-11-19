// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RemoteHostAppPermissions implements WireValue {
    private final Field<Boolean> accessibility;
    private final Field<Boolean> screenRecording;

    private RemoteHostAppPermissions(Builder builder) {
        this.accessibility = builder.accessibility;
        this.screenRecording = builder.screenRecording;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> accessibility() { return accessibility; }
    public Field<Boolean> screenRecording() { return screenRecording; }

    public static RemoteHostAppPermissions fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RemoteHostAppPermissions");
        Builder builder = builder();
        Object rawAccessibility = Wire.optional(object, "accessibility");
        if (!Wire.isMissing(rawAccessibility)) {
            builder.accessibility(rawAccessibility == null ? null : Wire.bool(rawAccessibility, "RemoteHostAppPermissions.accessibility"));
        }
        Object rawScreenRecording = Wire.optional(object, "screen_recording");
        if (!Wire.isMissing(rawScreenRecording)) {
            builder.screenRecording(rawScreenRecording == null ? null : Wire.bool(rawScreenRecording, "RemoteHostAppPermissions.screen_recording"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "accessibility", accessibility);
        Wire.put(object, "screen_recording", screenRecording);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RemoteHostAppPermissions that)) return false;
        return Objects.equals(accessibility, that.accessibility) && Objects.equals(screenRecording, that.screenRecording);
    }

    @Override
    public int hashCode() { return Objects.hash(accessibility, screenRecording); }

    @Override
    public String toString() { return "RemoteHostAppPermissions" + toWire(); }

    public static final class Builder {
        private Field<Boolean> accessibility = Field.omitted();
        private Field<Boolean> screenRecording = Field.omitted();

        public Builder accessibility(Boolean value) {
            this.accessibility = Field.ofNullable(value);
            return this;
        }
        public Builder screenRecording(Boolean value) {
            this.screenRecording = Field.ofNullable(value);
            return this;
        }
        public RemoteHostAppPermissions build() { return new RemoteHostAppPermissions(this); }
    }
}
