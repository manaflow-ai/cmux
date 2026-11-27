// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable remote-host-config request. Protocol v12; authority: local-admin. */
public final class RemoteHostConfigRequest implements WireValue {
    private final Field<Boolean> computerUse;
    private final Field<Boolean> headless;
    private final Field<Boolean> screenSharing;

    private RemoteHostConfigRequest(Builder builder) {
        this.computerUse = builder.computerUse;
        this.headless = builder.headless;
        this.screenSharing = builder.screenSharing;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> computerUse() { return computerUse; }
    public Field<Boolean> headless() { return headless; }
    public Field<Boolean> screenSharing() { return screenSharing; }

    public static RemoteHostConfigRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RemoteHostConfigRequest");
        Builder builder = builder();
        Object rawComputerUse = Wire.optional(object, "computer_use");
        if (!Wire.isMissing(rawComputerUse)) {
            builder.computerUse(rawComputerUse == null ? null : Wire.bool(rawComputerUse, "RemoteHostConfigRequest.computer_use"));
        }
        Object rawHeadless = Wire.optional(object, "headless");
        if (!Wire.isMissing(rawHeadless)) {
            builder.headless(rawHeadless == null ? null : Wire.bool(rawHeadless, "RemoteHostConfigRequest.headless"));
        }
        Object rawScreenSharing = Wire.optional(object, "screen_sharing");
        if (!Wire.isMissing(rawScreenSharing)) {
            builder.screenSharing(rawScreenSharing == null ? null : Wire.bool(rawScreenSharing, "RemoteHostConfigRequest.screen_sharing"));
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
        if (!(other instanceof RemoteHostConfigRequest that)) return false;
        return Objects.equals(computerUse, that.computerUse) && Objects.equals(headless, that.headless) && Objects.equals(screenSharing, that.screenSharing);
    }

    @Override
    public int hashCode() { return Objects.hash(computerUse, headless, screenSharing); }

    @Override
    public String toString() { return "RemoteHostConfigRequest" + toWire(); }

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
        public RemoteHostConfigRequest build() { return new RemoteHostConfigRequest(this); }
    }
}
