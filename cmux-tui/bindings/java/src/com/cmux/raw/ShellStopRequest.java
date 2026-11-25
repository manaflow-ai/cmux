// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable shell-stop request. Protocol v12; authority: control. */
public final class ShellStopRequest implements WireValue {
    private final String run;

    private ShellStopRequest(Builder builder) {
        if (!builder.runSet) throw new IllegalArgumentException("run is required");
        this.run = Wire.nonNull(builder.run, "run");
    }

    public static Builder builder() { return new Builder(); }

    public String run() { return run; }

    public static ShellStopRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ShellStopRequest");
        Builder builder = builder();
        Object rawRun = Wire.required(object, "run");
        builder.run(Wire.string(rawRun, "ShellStopRequest.run"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "run", run);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ShellStopRequest that)) return false;
        return Objects.equals(run, that.run);
    }

    @Override
    public int hashCode() { return Objects.hash(run); }

    @Override
    public String toString() { return "ShellStopRequest" + toWire(); }

    public static final class Builder {
        private String run;
        private boolean runSet;

        public Builder run(String value) {
            this.run = value;
            this.runSet = true;
            return this;
        }
        public ShellStopRequest build() { return new ShellStopRequest(this); }
    }
}
