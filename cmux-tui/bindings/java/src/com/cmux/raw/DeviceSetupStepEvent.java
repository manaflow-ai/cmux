// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable device-setup-step event. Protocol v12; streams: control. */
public final class DeviceSetupStepEvent implements WireValue, ProtocolEvent {
    private final String detail;
    private final String device;
    private final String fix;
    private final String state;
    private final String step;

    private DeviceSetupStepEvent(Builder builder) {
        if (!builder.detailSet) throw new IllegalArgumentException("detail is required");
        this.detail = Wire.nonNull(builder.detail, "detail");
        if (!builder.deviceSet) throw new IllegalArgumentException("device is required");
        this.device = Wire.nonNull(builder.device, "device");
        if (!builder.fixSet) throw new IllegalArgumentException("fix is required");
        this.fix = Wire.nonNull(builder.fix, "fix");
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
        if (!builder.stepSet) throw new IllegalArgumentException("step is required");
        this.step = Wire.nonNull(builder.step, "step");
    }

    public static Builder builder() { return new Builder(); }

    public String detail() { return detail; }
    public String device() { return device; }
    public String fix() { return fix; }
    public String state() { return state; }
    public String step() { return step; }
    @Override public String event() { return "device-setup-step"; }

    public static DeviceSetupStepEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "DeviceSetupStepEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "device-setup-step", "DeviceSetupStepEvent.event");
        Object rawDetail = Wire.required(object, "detail");
        builder.detail(Wire.string(rawDetail, "DeviceSetupStepEvent.detail"));
        Object rawDevice = Wire.required(object, "device");
        builder.device(Wire.string(rawDevice, "DeviceSetupStepEvent.device"));
        Object rawFix = Wire.required(object, "fix");
        builder.fix(Wire.string(rawFix, "DeviceSetupStepEvent.fix"));
        Object rawState = Wire.required(object, "state");
        builder.state(Wire.string(rawState, "DeviceSetupStepEvent.state"));
        Object rawStep = Wire.required(object, "step");
        builder.step(Wire.string(rawStep, "DeviceSetupStepEvent.step"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "device-setup-step");
        Wire.put(object, "detail", detail);
        Wire.put(object, "device", device);
        Wire.put(object, "fix", fix);
        Wire.put(object, "state", state);
        Wire.put(object, "step", step);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof DeviceSetupStepEvent that)) return false;
        return Objects.equals(detail, that.detail) && Objects.equals(device, that.device) && Objects.equals(fix, that.fix) && Objects.equals(state, that.state) && Objects.equals(step, that.step);
    }

    @Override
    public int hashCode() { return Objects.hash(detail, device, fix, state, step); }

    @Override
    public String toString() { return "DeviceSetupStepEvent" + toWire(); }

    public static final class Builder {
        private String detail;
        private boolean detailSet;
        private String device;
        private boolean deviceSet;
        private String fix;
        private boolean fixSet;
        private String state;
        private boolean stateSet;
        private String step;
        private boolean stepSet;

        public Builder detail(String value) {
            this.detail = value;
            this.detailSet = true;
            return this;
        }
        public Builder device(String value) {
            this.device = value;
            this.deviceSet = true;
            return this;
        }
        public Builder fix(String value) {
            this.fix = value;
            this.fixSet = true;
            return this;
        }
        public Builder state(String value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public Builder step(String value) {
            this.step = value;
            this.stepSet = true;
            return this;
        }
        public DeviceSetupStepEvent build() { return new DeviceSetupStepEvent(this); }
    }
}
