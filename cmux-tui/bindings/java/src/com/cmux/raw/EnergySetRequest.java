// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable energy.set request. Protocol v12; authority: local-admin. */
public final class EnergySetRequest implements WireValue {
    private final Field<Boolean> offForNow;
    private final Field<EnergySaverReason> reason;
    private final Boolean saver;

    private EnergySetRequest(Builder builder) {
        this.offForNow = builder.offForNow;
        this.reason = builder.reason;
        if (!builder.saverSet) throw new IllegalArgumentException("saver is required");
        this.saver = builder.saver;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> offForNow() { return offForNow; }
    public Field<EnergySaverReason> reason() { return reason; }
    public Boolean saver() { return saver; }

    public static EnergySetRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "EnergySetRequest");
        Builder builder = builder();
        Object rawOffForNow = Wire.optional(object, "offForNow");
        if (!Wire.isMissing(rawOffForNow)) {
            builder.offForNow(rawOffForNow == null ? null : Wire.bool(rawOffForNow, "EnergySetRequest.offForNow"));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : EnergySaverReason.fromWire(rawReason));
        }
        Object rawSaver = Wire.required(object, "saver");
        builder.saver(rawSaver == null ? null : Wire.bool(rawSaver, "EnergySetRequest.saver"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "offForNow", offForNow);
        Wire.put(object, "reason", reason);
        Wire.put(object, "saver", saver);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof EnergySetRequest that)) return false;
        return Objects.equals(offForNow, that.offForNow) && Objects.equals(reason, that.reason) && Objects.equals(saver, that.saver);
    }

    @Override
    public int hashCode() { return Objects.hash(offForNow, reason, saver); }

    @Override
    public String toString() { return "EnergySetRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> offForNow = Field.omitted();
        private Field<EnergySaverReason> reason = Field.omitted();
        private Boolean saver;
        private boolean saverSet;

        public Builder offForNow(Boolean value) {
            this.offForNow = Field.ofNullable(value);
            return this;
        }
        public Builder reason(EnergySaverReason value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder saver(Boolean value) {
            this.saver = value;
            this.saverSet = true;
            return this;
        }
        public EnergySetRequest build() { return new EnergySetRequest(this); }
    }
}
