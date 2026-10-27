// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentInventoryHarness implements WireValue {
    private final AgentInventoryAuth auth;
    private final AgentInventoryChannel channel;
    /** When the owner's health check saved this row, in Unix milliseconds. */
    private final UInt64 checkedAt;
    /** Recognized CLI family from the owner's saved health check; null for launchers, missing executables, conflicting evidence and families this daemon does not know. */
    private final AgentInventoryFamily family;
    /** Harness profile id: 1-128 bytes of `[A-Za-z0-9._-]`. */
    private final String id;
    /** Latest registry version from the last successful check, or null. */
    private final String latest;
    /** When `latest` was checked, in Unix milliseconds; null when never checked. */
    private final UInt64 latestCheckedAt;
    /** True only when `version` and `latest` are both known and `latest` is newer. */
    private final boolean outdated;
    /** Installed semantic version, or null when unknown. */
    private final String version;

    private AgentInventoryHarness(Builder builder) {
        if (!builder.authSet) throw new IllegalArgumentException("auth is required");
        this.auth = Wire.nonNull(builder.auth, "auth");
        if (!builder.channelSet) throw new IllegalArgumentException("channel is required");
        this.channel = Wire.nonNull(builder.channel, "channel");
        if (!builder.checkedAtSet) throw new IllegalArgumentException("checkedAt is required");
        this.checkedAt = Wire.nonNull(builder.checkedAt, "checkedAt");
        if (!builder.familySet) throw new IllegalArgumentException("family is required");
        this.family = builder.family;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.latestSet) throw new IllegalArgumentException("latest is required");
        this.latest = builder.latest;
        if (!builder.latestCheckedAtSet) throw new IllegalArgumentException("latestCheckedAt is required");
        this.latestCheckedAt = builder.latestCheckedAt;
        if (!builder.outdatedSet) throw new IllegalArgumentException("outdated is required");
        this.outdated = builder.outdated;
        if (!builder.versionSet) throw new IllegalArgumentException("version is required");
        this.version = builder.version;
    }

    public static Builder builder() { return new Builder(); }

    public AgentInventoryAuth auth() { return auth; }
    public AgentInventoryChannel channel() { return channel; }
    public UInt64 checkedAt() { return checkedAt; }
    public AgentInventoryFamily family() { return family; }
    public String id() { return id; }
    public String latest() { return latest; }
    public UInt64 latestCheckedAt() { return latestCheckedAt; }
    public boolean outdated() { return outdated; }
    public String version() { return version; }

    public static AgentInventoryHarness fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentInventoryHarness");
        Builder builder = builder();
        Object rawAuth = Wire.required(object, "auth");
        builder.auth(AgentInventoryAuth.fromWire(rawAuth));
        Object rawChannel = Wire.required(object, "channel");
        builder.channel(AgentInventoryChannel.fromWire(rawChannel));
        Object rawCheckedAt = Wire.required(object, "checkedAt");
        builder.checkedAt(Wire.uint64(rawCheckedAt, "AgentInventoryHarness.checkedAt"));
        Object rawFamily = Wire.required(object, "family");
        builder.family(rawFamily == null ? null : AgentInventoryFamily.fromWire(rawFamily));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "AgentInventoryHarness.id"));
        Object rawLatest = Wire.required(object, "latest");
        builder.latest(rawLatest == null ? null : Wire.string(rawLatest, "AgentInventoryHarness.latest"));
        Object rawLatestCheckedAt = Wire.required(object, "latestCheckedAt");
        builder.latestCheckedAt(rawLatestCheckedAt == null ? null : Wire.uint64(rawLatestCheckedAt, "AgentInventoryHarness.latestCheckedAt"));
        Object rawOutdated = Wire.required(object, "outdated");
        builder.outdated(Wire.bool(rawOutdated, "AgentInventoryHarness.outdated"));
        Object rawVersion = Wire.required(object, "version");
        builder.version(rawVersion == null ? null : Wire.string(rawVersion, "AgentInventoryHarness.version"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "auth", auth);
        Wire.put(object, "channel", channel);
        Wire.put(object, "checkedAt", checkedAt);
        Wire.put(object, "family", family);
        Wire.put(object, "id", id);
        Wire.put(object, "latest", latest);
        Wire.put(object, "latestCheckedAt", latestCheckedAt);
        Wire.put(object, "outdated", outdated);
        Wire.put(object, "version", version);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentInventoryHarness that)) return false;
        return Objects.equals(auth, that.auth) && Objects.equals(channel, that.channel) && Objects.equals(checkedAt, that.checkedAt) && Objects.equals(family, that.family) && Objects.equals(id, that.id) && Objects.equals(latest, that.latest) && Objects.equals(latestCheckedAt, that.latestCheckedAt) && Objects.equals(outdated, that.outdated) && Objects.equals(version, that.version);
    }

    @Override
    public int hashCode() { return Objects.hash(auth, channel, checkedAt, family, id, latest, latestCheckedAt, outdated, version); }

    @Override
    public String toString() { return "AgentInventoryHarness" + toWire(); }

    public static final class Builder {
        private AgentInventoryAuth auth;
        private boolean authSet;
        private AgentInventoryChannel channel;
        private boolean channelSet;
        private UInt64 checkedAt;
        private boolean checkedAtSet;
        private AgentInventoryFamily family;
        private boolean familySet;
        private String id;
        private boolean idSet;
        private String latest;
        private boolean latestSet;
        private UInt64 latestCheckedAt;
        private boolean latestCheckedAtSet;
        private Boolean outdated;
        private boolean outdatedSet;
        private String version;
        private boolean versionSet;

        public Builder auth(AgentInventoryAuth value) {
            this.auth = value;
            this.authSet = true;
            return this;
        }
        public Builder channel(AgentInventoryChannel value) {
            this.channel = value;
            this.channelSet = true;
            return this;
        }
        public Builder checkedAt(UInt64 value) {
            this.checkedAt = value;
            this.checkedAtSet = true;
            return this;
        }
        public Builder family(AgentInventoryFamily value) {
            this.family = value;
            this.familySet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder latest(String value) {
            this.latest = value;
            this.latestSet = true;
            return this;
        }
        public Builder latestCheckedAt(UInt64 value) {
            this.latestCheckedAt = value;
            this.latestCheckedAtSet = true;
            return this;
        }
        public Builder outdated(boolean value) {
            this.outdated = value;
            this.outdatedSet = true;
            return this;
        }
        public Builder version(String value) {
            this.version = value;
            this.versionSet = true;
            return this;
        }
        public AgentInventoryHarness build() { return new AgentInventoryHarness(this); }
    }
}
