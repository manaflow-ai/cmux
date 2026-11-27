// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable shell-read request. Protocol v12; authority: control. */
public final class ShellReadRequest implements WireValue {
    private final Field<UInt64> after;
    private final String run;
    private final Field<UInt64> waitMs;

    private ShellReadRequest(Builder builder) {
        this.after = builder.after;
        if (!builder.runSet) throw new IllegalArgumentException("run is required");
        this.run = Wire.nonNull(builder.run, "run");
        this.waitMs = builder.waitMs;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> after() { return after; }
    public String run() { return run; }
    public Field<UInt64> waitMs() { return waitMs; }

    public static ShellReadRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ShellReadRequest");
        Builder builder = builder();
        Object rawAfter = Wire.optional(object, "after");
        if (!Wire.isMissing(rawAfter)) {
            builder.after(Wire.uint64(rawAfter, "ShellReadRequest.after"));
        }
        Object rawRun = Wire.required(object, "run");
        builder.run(Wire.string(rawRun, "ShellReadRequest.run"));
        Object rawWaitMs = Wire.optional(object, "wait_ms");
        if (!Wire.isMissing(rawWaitMs)) {
            builder.waitMs(rawWaitMs == null ? null : Wire.uint64(rawWaitMs, "ShellReadRequest.wait_ms"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after", after);
        Wire.put(object, "run", run);
        Wire.put(object, "wait_ms", waitMs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ShellReadRequest that)) return false;
        return Objects.equals(after, that.after) && Objects.equals(run, that.run) && Objects.equals(waitMs, that.waitMs);
    }

    @Override
    public int hashCode() { return Objects.hash(after, run, waitMs); }

    @Override
    public String toString() { return "ShellReadRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> after = Field.omitted();
        private String run;
        private boolean runSet;
        private Field<UInt64> waitMs = Field.omitted();

        public Builder after(UInt64 value) {
            this.after = Field.of(value);
            return this;
        }
        public Builder run(String value) {
            this.run = value;
            this.runSet = true;
            return this;
        }
        public Builder waitMs(UInt64 value) {
            this.waitMs = Field.ofNullable(value);
            return this;
        }
        public ShellReadRequest build() { return new ShellReadRequest(this); }
    }
}
