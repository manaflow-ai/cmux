// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-client-info request. Protocol v6; authority: control. */
public final class SetClientInfoRequest implements WireValue {
    private final Field<List<String>> capabilities;
    private final Field<String> deviceId;
    private final Field<String> deviceKind;
    private final Field<String> deviceName;
    private final Field<String> displayName;
    private final Field<String> kind;
    private final Field<String> name;
    private final Field<String> userId;

    private SetClientInfoRequest(Builder builder) {
        this.capabilities = builder.capabilities.map(value -> List.copyOf(value));
        this.deviceId = builder.deviceId;
        this.deviceKind = builder.deviceKind;
        this.deviceName = builder.deviceName;
        this.displayName = builder.displayName;
        this.kind = builder.kind;
        this.name = builder.name;
        this.userId = builder.userId;
    }

    public static Builder builder() { return new Builder(); }

    public Field<List<String>> capabilities() { return capabilities; }
    public Field<String> deviceId() { return deviceId; }
    public Field<String> deviceKind() { return deviceKind; }
    public Field<String> deviceName() { return deviceName; }
    public Field<String> displayName() { return displayName; }
    public Field<String> kind() { return kind; }
    public Field<String> name() { return name; }
    public Field<String> userId() { return userId; }

    public static SetClientInfoRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetClientInfoRequest");
        Builder builder = builder();
        Object rawCapabilities = Wire.optional(object, "capabilities");
        if (!Wire.isMissing(rawCapabilities)) {
            builder.capabilities(rawCapabilities == null ? null : Wire.array(rawCapabilities, "SetClientInfoRequest.capabilities", item -> Wire.string(item, "SetClientInfoRequest.capabilities item")));
        }
        Object rawDeviceId = Wire.optional(object, "device_id");
        if (!Wire.isMissing(rawDeviceId)) {
            builder.deviceId(rawDeviceId == null ? null : Wire.string(rawDeviceId, "SetClientInfoRequest.device_id"));
        }
        Object rawDeviceKind = Wire.optional(object, "device_kind");
        if (!Wire.isMissing(rawDeviceKind)) {
            builder.deviceKind(rawDeviceKind == null ? null : Wire.string(rawDeviceKind, "SetClientInfoRequest.device_kind"));
        }
        Object rawDeviceName = Wire.optional(object, "device_name");
        if (!Wire.isMissing(rawDeviceName)) {
            builder.deviceName(rawDeviceName == null ? null : Wire.string(rawDeviceName, "SetClientInfoRequest.device_name"));
        }
        Object rawDisplayName = Wire.optional(object, "display_name");
        if (!Wire.isMissing(rawDisplayName)) {
            builder.displayName(rawDisplayName == null ? null : Wire.string(rawDisplayName, "SetClientInfoRequest.display_name"));
        }
        Object rawKind = Wire.optional(object, "kind");
        if (!Wire.isMissing(rawKind)) {
            builder.kind(rawKind == null ? null : Wire.string(rawKind, "SetClientInfoRequest.kind"));
        }
        Object rawName = Wire.optional(object, "name");
        if (!Wire.isMissing(rawName)) {
            builder.name(rawName == null ? null : Wire.string(rawName, "SetClientInfoRequest.name"));
        }
        Object rawUserId = Wire.optional(object, "user_id");
        if (!Wire.isMissing(rawUserId)) {
            builder.userId(rawUserId == null ? null : Wire.string(rawUserId, "SetClientInfoRequest.user_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "capabilities", capabilities);
        Wire.put(object, "device_id", deviceId);
        Wire.put(object, "device_kind", deviceKind);
        Wire.put(object, "device_name", deviceName);
        Wire.put(object, "display_name", displayName);
        Wire.put(object, "kind", kind);
        Wire.put(object, "name", name);
        Wire.put(object, "user_id", userId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetClientInfoRequest that)) return false;
        return Objects.equals(capabilities, that.capabilities) && Objects.equals(deviceId, that.deviceId) && Objects.equals(deviceKind, that.deviceKind) && Objects.equals(deviceName, that.deviceName) && Objects.equals(displayName, that.displayName) && Objects.equals(kind, that.kind) && Objects.equals(name, that.name) && Objects.equals(userId, that.userId);
    }

    @Override
    public int hashCode() { return Objects.hash(capabilities, deviceId, deviceKind, deviceName, displayName, kind, name, userId); }

    @Override
    public String toString() { return "SetClientInfoRequest" + toWire(); }

    public static final class Builder {
        private Field<List<String>> capabilities = Field.omitted();
        private Field<String> deviceId = Field.omitted();
        private Field<String> deviceKind = Field.omitted();
        private Field<String> deviceName = Field.omitted();
        private Field<String> displayName = Field.omitted();
        private Field<String> kind = Field.omitted();
        private Field<String> name = Field.omitted();
        private Field<String> userId = Field.omitted();

        public Builder capabilities(List<String> value) {
            this.capabilities = Field.ofNullable(value);
            return this;
        }
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
        public Builder kind(String value) {
            this.kind = Field.ofNullable(value);
            return this;
        }
        public Builder name(String value) {
            this.name = Field.ofNullable(value);
            return this;
        }
        public Builder userId(String value) {
            this.userId = Field.ofNullable(value);
            return this;
        }
        public SetClientInfoRequest build() { return new SetClientInfoRequest(this); }
    }
}
