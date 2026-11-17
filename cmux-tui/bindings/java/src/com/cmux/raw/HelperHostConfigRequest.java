// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable helper-host-config request. Protocol v12; authority: local-admin. */
public final class HelperHostConfigRequest implements WireValue {
    private final Field<Boolean> computerUse;
    private final Field<Boolean> headless;
    private final Field<Boolean> screenSharing;

    private HelperHostConfigRequest(Builder builder) {
        this.computerUse = builder.computerUse;
        this.headless = builder.headless;
        this.screenSharing = builder.screenSharing;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> computerUse() { return computerUse; }
    public Field<Boolean> headless() { return headless; }
    public Field<Boolean> screenSharing() { return screenSharing; }

    public static HelperHostConfigRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HelperHostConfigRequest");
        Builder builder = builder();
        Object rawComputerUse = Wire.optional(object, "computer_use");
        if (!Wire.isMissing(rawComputerUse)) {
            builder.computerUse(rawComputerUse == null ? null : Wire.bool(rawComputerUse, "HelperHostConfigRequest.computer_use"));
        }
        Object rawHeadless = Wire.optional(object, "headless");
        if (!Wire.isMissing(rawHeadless)) {
            builder.headless(rawHeadless == null ? null : Wire.bool(rawHeadless, "HelperHostConfigRequest.headless"));
        }
        Object rawScreenSharing = Wire.optional(object, "screen_sharing");
        if (!Wire.isMissing(rawScreenSharing)) {
            builder.screenSharing(rawScreenSharing == null ? null : Wire.bool(rawScreenSharing, "HelperHostConfigRequest.screen_sharing"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "computer_use", computerUse);
        Wire.put(object, "headless", headless);
        Wire.put(object, "screen_sharing", screenSharing);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HelperHostConfigRequest that)) return false;
        return Objects.equals(computerUse, that.computerUse) && Objects.equals(headless, that.headless) && Objects.equals(screenSharing, that.screenSharing);
    }

    @Override
    public int hashCode() { return Objects.hash(computerUse, headless, screenSharing); }

    @Override
    public String toString() { return "HelperHostConfigRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> computerUse = Field.omitted();
        private Field<Boolean> headless = Field.omitted();
        private Field<Boolean> screenSharing = Field.omitted();

        public Builder computerUse(Boolean value) {
            this.computerUse = Field.ofNullable(value);
            return this;
        }
        public Builder headless(Boolean value) {
            this.headless = Field.ofNullable(value);
            return this;
        }
        public Builder screenSharing(Boolean value) {
            this.screenSharing = Field.ofNullable(value);
            return this;
        }
        public HelperHostConfigRequest build() { return new HelperHostConfigRequest(this); }
    }
}
