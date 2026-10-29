// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class EnergyStatus implements WireValue {
    private final boolean offForNow;
    private final Boolean override;
    private final boolean reading;
    private final EnergySaverReason reason;
    private final boolean saver;
    private final EnergySaverSetting setting;
    private final EnergySource source;

    private EnergyStatus(Builder builder) {
        if (!builder.offForNowSet) throw new IllegalArgumentException("offForNow is required");
        this.offForNow = builder.offForNow;
        if (!builder.overrideSet) throw new IllegalArgumentException("override is required");
        this.override = builder.override;
        if (!builder.readingSet) throw new IllegalArgumentException("reading is required");
        this.reading = builder.reading;
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = builder.reason;
        if (!builder.saverSet) throw new IllegalArgumentException("saver is required");
        this.saver = builder.saver;
        if (!builder.settingSet) throw new IllegalArgumentException("setting is required");
        this.setting = builder.setting;
        if (!builder.sourceSet) throw new IllegalArgumentException("source is required");
        this.source = Wire.nonNull(builder.source, "source");
    }

    public static Builder builder() { return new Builder(); }

    public boolean offForNow() { return offForNow; }
    public Boolean override() { return override; }
    public boolean reading() { return reading; }
    public EnergySaverReason reason() { return reason; }
    public boolean saver() { return saver; }
    public EnergySaverSetting setting() { return setting; }
    public EnergySource source() { return source; }

    public static EnergyStatus fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "EnergyStatus");
        Builder builder = builder();
        Object rawOffForNow = Wire.required(object, "offForNow");
        builder.offForNow(Wire.bool(rawOffForNow, "EnergyStatus.offForNow"));
        Object rawOverride = Wire.required(object, "override");
        builder.override(rawOverride == null ? null : Wire.bool(rawOverride, "EnergyStatus.override"));
        Object rawReading = Wire.required(object, "reading");
        builder.reading(Wire.bool(rawReading, "EnergyStatus.reading"));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(rawReason == null ? null : EnergySaverReason.fromWire(rawReason));
        Object rawSaver = Wire.required(object, "saver");
        builder.saver(Wire.bool(rawSaver, "EnergyStatus.saver"));
        Object rawSetting = Wire.required(object, "setting");
        builder.setting(rawSetting == null ? null : EnergySaverSetting.fromWire(rawSetting));
        Object rawSource = Wire.required(object, "source");
        builder.source(EnergySource.fromWire(rawSource));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "offForNow", offForNow);
        Wire.put(object, "override", override);
        Wire.put(object, "reading", reading);
        Wire.put(object, "reason", reason);
        Wire.put(object, "saver", saver);
        Wire.put(object, "setting", setting);
        Wire.put(object, "source", source);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof EnergyStatus that)) return false;
        return Objects.equals(offForNow, that.offForNow) && Objects.equals(override, that.override) && Objects.equals(reading, that.reading) && Objects.equals(reason, that.reason) && Objects.equals(saver, that.saver) && Objects.equals(setting, that.setting) && Objects.equals(source, that.source);
    }

    @Override
    public int hashCode() { return Objects.hash(offForNow, override, reading, reason, saver, setting, source); }

    @Override
    public String toString() { return "EnergyStatus" + toWire(); }

    public static final class Builder {
        private Boolean offForNow;
        private boolean offForNowSet;
        private Boolean override;
        private boolean overrideSet;
        private Boolean reading;
        private boolean readingSet;
        private EnergySaverReason reason;
        private boolean reasonSet;
        private Boolean saver;
        private boolean saverSet;
        private EnergySaverSetting setting;
        private boolean settingSet;
        private EnergySource source;
        private boolean sourceSet;

        public Builder offForNow(boolean value) {
            this.offForNow = value;
            this.offForNowSet = true;
            return this;
        }
        public Builder override(Boolean value) {
            this.override = value;
            this.overrideSet = true;
            return this;
        }
        public Builder reading(boolean value) {
            this.reading = value;
            this.readingSet = true;
            return this;
        }
        public Builder reason(EnergySaverReason value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public Builder saver(boolean value) {
            this.saver = value;
            this.saverSet = true;
            return this;
        }
        public Builder setting(EnergySaverSetting value) {
            this.setting = value;
            this.settingSet = true;
            return this;
        }
        public Builder source(EnergySource value) {
            this.source = value;
            this.sourceSet = true;
            return this;
        }
        public EnergyStatus build() { return new EnergyStatus(this); }
    }
}
