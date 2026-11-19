// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable device-setup request. Protocol v12; authority: local-admin. */
public final class DeviceSetupRequest implements WireValue {
    /** Turn on the agents permission (the person's click in the app). */
    private final Field<Boolean> allowAgents;
    /** A device id, name or address, as `cmux device list` shows it. */
    private final String device;
    private final Field<Boolean> dryRun;
    /** setup (every step) or start (reach, login item and start). */
    private final String verb;

    private DeviceSetupRequest(Builder builder) {
        this.allowAgents = builder.allowAgents;
        if (!builder.deviceSet) throw new IllegalArgumentException("device is required");
        this.device = Wire.nonNull(builder.device, "device");
        this.dryRun = builder.dryRun;
        if (!builder.verbSet) throw new IllegalArgumentException("verb is required");
        this.verb = Wire.nonNull(builder.verb, "verb");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> allowAgents() { return allowAgents; }
    public String device() { return device; }
    public Field<Boolean> dryRun() { return dryRun; }
    public String verb() { return verb; }

    public static DeviceSetupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeviceSetupRequest");
        Builder builder = builder();
        Object rawAllowAgents = Wire.optional(object, "allow_agents");
        if (!Wire.isMissing(rawAllowAgents)) {
            builder.allowAgents(Wire.bool(rawAllowAgents, "DeviceSetupRequest.allow_agents"));
        }
        Object rawDevice = Wire.required(object, "device");
        builder.device(Wire.string(rawDevice, "DeviceSetupRequest.device"));
        Object rawDryRun = Wire.optional(object, "dry_run");
        if (!Wire.isMissing(rawDryRun)) {
            builder.dryRun(Wire.bool(rawDryRun, "DeviceSetupRequest.dry_run"));
        }
        Object rawVerb = Wire.required(object, "verb");
        builder.verb(Wire.string(rawVerb, "DeviceSetupRequest.verb"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "allow_agents", allowAgents);
        Wire.put(object, "device", device);
        Wire.put(object, "dry_run", dryRun);
        Wire.put(object, "verb", verb);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeviceSetupRequest that)) return false;
        return Objects.equals(allowAgents, that.allowAgents) && Objects.equals(device, that.device) && Objects.equals(dryRun, that.dryRun) && Objects.equals(verb, that.verb);
    }

    @Override
    public int hashCode() { return Objects.hash(allowAgents, device, dryRun, verb); }

    @Override
    public String toString() { return "DeviceSetupRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> allowAgents = Field.omitted();
        private String device;
        private boolean deviceSet;
        private Field<Boolean> dryRun = Field.omitted();
        private String verb;
        private boolean verbSet;

        public Builder allowAgents(Boolean value) {
            this.allowAgents = Field.of(value);
            return this;
        }
        public Builder device(String value) {
            this.device = value;
            this.deviceSet = true;
            return this;
        }
        public Builder dryRun(Boolean value) {
            this.dryRun = Field.of(value);
            return this;
        }
        public Builder verb(String value) {
            this.verb = value;
            this.verbSet = true;
            return this;
        }
        public DeviceSetupRequest build() { return new DeviceSetupRequest(this); }
    }
}
