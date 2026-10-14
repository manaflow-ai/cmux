// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SizingIdentity implements WireValue {
    private final Field<String> deviceId;
    private final Field<String> deviceKind;
    private final Field<String> deviceName;
    private final Field<String> displayName;
    private final Field<String> userId;

    private SizingIdentity(Builder builder) {
        this.deviceId = builder.deviceId;
        this.deviceKind = builder.deviceKind;
        this.deviceName = builder.deviceName;
        this.displayName = builder.displayName;
        this.userId = builder.userId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> deviceId() { return deviceId; }
    public Field<String> deviceKind() { return deviceKind; }
    public Field<String> deviceName() { return deviceName; }
    public Field<String> displayName() { return displayName; }
    public Field<String> userId() { return userId; }

    public static SizingIdentity fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SizingIdentity");
        Builder builder = builder();
        Object rawDeviceId = Wire.optional(object, "device_id");
        if (!Wire.isMissing(rawDeviceId)) {
            builder.deviceId(rawDeviceId == null ? null : Wire.string(rawDeviceId, "SizingIdentity.device_id"));
        }
        Object rawDeviceKind = Wire.optional(object, "device_kind");
        if (!Wire.isMissing(rawDeviceKind)) {
            builder.deviceKind(rawDeviceKind == null ? null : Wire.string(rawDeviceKind, "SizingIdentity.device_kind"));
        }
        Object rawDeviceName = Wire.optional(object, "device_name");
        if (!Wire.isMissing(rawDeviceName)) {
            builder.deviceName(rawDeviceName == null ? null : Wire.string(rawDeviceName, "SizingIdentity.device_name"));
        }
        Object rawDisplayName = Wire.optional(object, "display_name");
        if (!Wire.isMissing(rawDisplayName)) {
            builder.displayName(rawDisplayName == null ? null : Wire.string(rawDisplayName, "SizingIdentity.display_name"));
        }
        Object rawUserId = Wire.optional(object, "user_id");
        if (!Wire.isMissing(rawUserId)) {
            builder.userId(rawUserId == null ? null : Wire.string(rawUserId, "SizingIdentity.user_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "device_id", deviceId);
        Wire.put(object, "device_kind", deviceKind);
        Wire.put(object, "device_name", deviceName);
        Wire.put(object, "display_name", displayName);
        Wire.put(object, "user_id", userId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SizingIdentity that)) return false;
        return Objects.equals(deviceId, that.deviceId) && Objects.equals(deviceKind, that.deviceKind) && Objects.equals(deviceName, that.deviceName) && Objects.equals(displayName, that.displayName) && Objects.equals(userId, that.userId);
    }

    @Override
    public int hashCode() { return Objects.hash(deviceId, deviceKind, deviceName, displayName, userId); }

    @Override
    public String toString() { return "SizingIdentity" + toWire(); }

    public static final class Builder {
        private Field<String> deviceId = Field.omitted();
        private Field<String> deviceKind = Field.omitted();
        private Field<String> deviceName = Field.omitted();
        private Field<String> displayName = Field.omitted();
        private Field<String> userId = Field.omitted();

        public Builder deviceId(String value) {
            this.deviceId = Field.ofNullable(value);
            return this;
        }
        public Builder deviceKind(String value) {
            this.deviceKind = Field.ofNullable(value);
            return this;
        }
        public Builder deviceName(String value) {
            this.deviceName = Field.ofNullable(value);
            return this;
        }
        public Builder displayName(String value) {
            this.displayName = Field.ofNullable(value);
            return this;
        }
        public Builder userId(String value) {
            this.userId = Field.ofNullable(value);
            return this;
        }
        public SizingIdentity build() { return new SizingIdentity(this); }
    }
}
