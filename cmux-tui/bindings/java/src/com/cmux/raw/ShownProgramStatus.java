// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ShownProgramStatus implements WireValue {
    private final Integer progress;
    private final ProgramStatusState state;

    private ShownProgramStatus(Builder builder) {
        if (!builder.progressSet) throw new IllegalArgumentException("progress is required");
        this.progress = builder.progress;
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
    }

    public static Builder builder() { return new Builder(); }

    public Integer progress() { return progress; }
    public ProgramStatusState state() { return state; }

    public static ShownProgramStatus fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ShownProgramStatus");
        Builder builder = builder();
        Object rawProgress = Wire.required(object, "progress");
        builder.progress(rawProgress == null ? null : Wire.uint16(rawProgress, "ShownProgramStatus.progress"));
        Object rawState = Wire.required(object, "state");
        builder.state(ProgramStatusState.fromWire(rawState));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "progress", progress);
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ShownProgramStatus that)) return false;
        return Objects.equals(progress, that.progress) && Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(progress, state); }

    @Override
    public String toString() { return "ShownProgramStatus" + toWire(); }

    public static final class Builder {
        private Integer progress;
        private boolean progressSet;
        private ProgramStatusState state;
        private boolean stateSet;

        public Builder progress(Integer value) {
            this.progress = value;
            this.progressSet = true;
            return this;
        }
        public Builder state(ProgramStatusState value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public ShownProgramStatus build() { return new ShownProgramStatus(this); }
    }
}
