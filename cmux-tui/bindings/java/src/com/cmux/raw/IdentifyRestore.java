// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class IdentifyRestore implements WireValue {
    private final UInt64 done;
    private final UInt64 elapsedMs;
    private final UInt64 lastAdvanceMs;
    private final String phase;
    private final UInt64 total;

    private IdentifyRestore(Builder builder) {
        if (!builder.doneSet) throw new IllegalArgumentException("done is required");
        this.done = builder.done;
        if (!builder.elapsedMsSet) throw new IllegalArgumentException("elapsed_ms is required");
        this.elapsedMs = Wire.nonNull(builder.elapsedMs, "elapsed_ms");
        if (!builder.lastAdvanceMsSet) throw new IllegalArgumentException("last_advance_ms is required");
        this.lastAdvanceMs = Wire.nonNull(builder.lastAdvanceMs, "last_advance_ms");
        if (!builder.phaseSet) throw new IllegalArgumentException("phase is required");
        this.phase = Wire.nonNull(builder.phase, "phase");
        if (!builder.totalSet) throw new IllegalArgumentException("total is required");
        this.total = builder.total;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 done() { return done; }
    public UInt64 elapsedMs() { return elapsedMs; }
    public UInt64 lastAdvanceMs() { return lastAdvanceMs; }
    public String phase() { return phase; }
    public UInt64 total() { return total; }

    public static IdentifyRestore fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "IdentifyRestore");
        Builder builder = builder();
        Object rawDone = Wire.required(object, "done");
        builder.done(rawDone == null ? null : Wire.uint64(rawDone, "IdentifyRestore.done"));
        Object rawElapsedMs = Wire.required(object, "elapsed_ms");
        builder.elapsedMs(Wire.uint64(rawElapsedMs, "IdentifyRestore.elapsed_ms"));
        Object rawLastAdvanceMs = Wire.required(object, "last_advance_ms");
        builder.lastAdvanceMs(Wire.uint64(rawLastAdvanceMs, "IdentifyRestore.last_advance_ms"));
        Object rawPhase = Wire.required(object, "phase");
        builder.phase(Wire.string(rawPhase, "IdentifyRestore.phase"));
        Object rawTotal = Wire.required(object, "total");
        builder.total(rawTotal == null ? null : Wire.uint64(rawTotal, "IdentifyRestore.total"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "done", done);
        Wire.put(object, "elapsed_ms", elapsedMs);
        Wire.put(object, "last_advance_ms", lastAdvanceMs);
        Wire.put(object, "phase", phase);
        Wire.put(object, "total", total);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof IdentifyRestore that)) return false;
        return Objects.equals(done, that.done) && Objects.equals(elapsedMs, that.elapsedMs) && Objects.equals(lastAdvanceMs, that.lastAdvanceMs) && Objects.equals(phase, that.phase) && Objects.equals(total, that.total);
    }

    @Override
    public int hashCode() { return Objects.hash(done, elapsedMs, lastAdvanceMs, phase, total); }

    @Override
    public String toString() { return "IdentifyRestore" + toWire(); }

    public static final class Builder {
        private UInt64 done;
        private boolean doneSet;
        private UInt64 elapsedMs;
        private boolean elapsedMsSet;
        private UInt64 lastAdvanceMs;
        private boolean lastAdvanceMsSet;
        private String phase;
        private boolean phaseSet;
        private UInt64 total;
        private boolean totalSet;

        public Builder done(UInt64 value) {
            this.done = value;
            this.doneSet = true;
            return this;
        }
        public Builder elapsedMs(UInt64 value) {
            this.elapsedMs = value;
            this.elapsedMsSet = true;
            return this;
        }
        public Builder lastAdvanceMs(UInt64 value) {
            this.lastAdvanceMs = value;
            this.lastAdvanceMsSet = true;
            return this;
        }
        public Builder phase(String value) {
            this.phase = value;
            this.phaseSet = true;
            return this;
        }
        public Builder total(UInt64 value) {
            this.total = value;
            this.totalSet = true;
            return this;
        }
        public IdentifyRestore build() { return new IdentifyRestore(this); }
    }
}
