// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SizeParticipant implements WireValue {
    private final boolean counts;
    private final Boolean countsOverride;
    private final String deviceId;
    private final SizeDeviceKind deviceKind;
    private final String deviceName;
    private final String displayName;
    private final String id;
    private final String priorityKey;
    private final String userId;
    private final String via;
    private final Size viewport;

    private SizeParticipant(Builder builder) {
        if (!builder.countsSet) throw new IllegalArgumentException("counts is required");
        this.counts = builder.counts;
        if (!builder.countsOverrideSet) throw new IllegalArgumentException("counts_override is required");
        this.countsOverride = builder.countsOverride;
        if (!builder.deviceIdSet) throw new IllegalArgumentException("device_id is required");
        this.deviceId = builder.deviceId;
        if (!builder.deviceKindSet) throw new IllegalArgumentException("device_kind is required");
        this.deviceKind = Wire.nonNull(builder.deviceKind, "device_kind");
        if (!builder.deviceNameSet) throw new IllegalArgumentException("device_name is required");
        this.deviceName = builder.deviceName;
        if (!builder.displayNameSet) throw new IllegalArgumentException("display_name is required");
        this.displayName = builder.displayName;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.priorityKeySet) throw new IllegalArgumentException("priority_key is required");
        this.priorityKey = Wire.nonNull(builder.priorityKey, "priority_key");
        if (!builder.userIdSet) throw new IllegalArgumentException("user_id is required");
        this.userId = builder.userId;
        if (!builder.viaSet) throw new IllegalArgumentException("via is required");
        this.via = builder.via;
        if (!builder.viewportSet) throw new IllegalArgumentException("viewport is required");
        this.viewport = builder.viewport;
    }

    public static Builder builder() { return new Builder(); }

    public boolean counts() { return counts; }
    public Boolean countsOverride() { return countsOverride; }
    public String deviceId() { return deviceId; }
    public SizeDeviceKind deviceKind() { return deviceKind; }
    public String deviceName() { return deviceName; }
    public String displayName() { return displayName; }
    public String id() { return id; }
    public String priorityKey() { return priorityKey; }
    public String userId() { return userId; }
    public String via() { return via; }
    public Size viewport() { return viewport; }

    public static SizeParticipant fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SizeParticipant");
        Builder builder = builder();
        Object rawCounts = Wire.required(object, "counts");
        builder.counts(Wire.bool(rawCounts, "SizeParticipant.counts"));
        Object rawCountsOverride = Wire.required(object, "counts_override");
        builder.countsOverride(rawCountsOverride == null ? null : Wire.bool(rawCountsOverride, "SizeParticipant.counts_override"));
        Object rawDeviceId = Wire.required(object, "device_id");
        builder.deviceId(rawDeviceId == null ? null : Wire.string(rawDeviceId, "SizeParticipant.device_id"));
        Object rawDeviceKind = Wire.required(object, "device_kind");
        builder.deviceKind(SizeDeviceKind.fromWire(rawDeviceKind));
        Object rawDeviceName = Wire.required(object, "device_name");
        builder.deviceName(rawDeviceName == null ? null : Wire.string(rawDeviceName, "SizeParticipant.device_name"));
        Object rawDisplayName = Wire.required(object, "display_name");
        builder.displayName(rawDisplayName == null ? null : Wire.string(rawDisplayName, "SizeParticipant.display_name"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "SizeParticipant.id"));
        Object rawPriorityKey = Wire.required(object, "priority_key");
        builder.priorityKey(Wire.string(rawPriorityKey, "SizeParticipant.priority_key"));
        Object rawUserId = Wire.required(object, "user_id");
        builder.userId(rawUserId == null ? null : Wire.string(rawUserId, "SizeParticipant.user_id"));
        Object rawVia = Wire.required(object, "via");
        builder.via(rawVia == null ? null : Wire.string(rawVia, "SizeParticipant.via"));
        Object rawViewport = Wire.required(object, "viewport");
        builder.viewport(rawViewport == null ? null : Size.fromWire(rawViewport));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "counts", counts);
        Wire.put(object, "counts_override", countsOverride);
        Wire.put(object, "device_id", deviceId);
        Wire.put(object, "device_kind", deviceKind);
        Wire.put(object, "device_name", deviceName);
        Wire.put(object, "display_name", displayName);
        Wire.put(object, "id", id);
        Wire.put(object, "priority_key", priorityKey);
        Wire.put(object, "user_id", userId);
        Wire.put(object, "via", via);
        Wire.put(object, "viewport", viewport);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SizeParticipant that)) return false;
        return Objects.equals(counts, that.counts) && Objects.equals(countsOverride, that.countsOverride) && Objects.equals(deviceId, that.deviceId) && Objects.equals(deviceKind, that.deviceKind) && Objects.equals(deviceName, that.deviceName) && Objects.equals(displayName, that.displayName) && Objects.equals(id, that.id) && Objects.equals(priorityKey, that.priorityKey) && Objects.equals(userId, that.userId) && Objects.equals(via, that.via) && Objects.equals(viewport, that.viewport);
    }

    @Override
    public int hashCode() { return Objects.hash(counts, countsOverride, deviceId, deviceKind, deviceName, displayName, id, priorityKey, userId, via, viewport); }

    @Override
    public String toString() { return "SizeParticipant" + toWire(); }

    public static final class Builder {
        private Boolean counts;
        private boolean countsSet;
        private Boolean countsOverride;
        private boolean countsOverrideSet;
        private String deviceId;
        private boolean deviceIdSet;
        private SizeDeviceKind deviceKind;
        private boolean deviceKindSet;
        private String deviceName;
        private boolean deviceNameSet;
        private String displayName;
        private boolean displayNameSet;
        private String id;
        private boolean idSet;
        private String priorityKey;
        private boolean priorityKeySet;
        private String userId;
        private boolean userIdSet;
        private String via;
        private boolean viaSet;
        private Size viewport;
        private boolean viewportSet;

        public Builder counts(boolean value) {
            this.counts = value;
            this.countsSet = true;
            return this;
        }
        public Builder countsOverride(Boolean value) {
            this.countsOverride = value;
            this.countsOverrideSet = true;
            return this;
        }
        public Builder deviceId(String value) {
            this.deviceId = value;
            this.deviceIdSet = true;
            return this;
        }
        public Builder deviceKind(SizeDeviceKind value) {
            this.deviceKind = value;
            this.deviceKindSet = true;
            return this;
        }
        public Builder deviceName(String value) {
            this.deviceName = value;
            this.deviceNameSet = true;
            return this;
        }
        public Builder displayName(String value) {
            this.displayName = value;
            this.displayNameSet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder priorityKey(String value) {
            this.priorityKey = value;
            this.priorityKeySet = true;
            return this;
        }
        public Builder userId(String value) {
            this.userId = value;
            this.userIdSet = true;
            return this;
        }
        public Builder via(String value) {
            this.via = value;
            this.viaSet = true;
            return this;
        }
        public Builder viewport(Size value) {
            this.viewport = value;
            this.viewportSet = true;
            return this;
        }
        public SizeParticipant build() { return new SizeParticipant(this); }
    }
}
