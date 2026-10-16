// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class MachineListeningTcpResult implements WireValue {
    private final String stdout;

    private MachineListeningTcpResult(Builder builder) {
        if (!builder.stdoutSet) throw new IllegalArgumentException("stdout is required");
        this.stdout = Wire.nonNull(builder.stdout, "stdout");
    }

    public static Builder builder() { return new Builder(); }

    public String stdout() { return stdout; }

    public static MachineListeningTcpResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MachineListeningTcpResult");
        Builder builder = builder();
        Object rawStdout = Wire.required(object, "stdout");
        builder.stdout(Wire.string(rawStdout, "MachineListeningTcpResult.stdout"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "stdout", stdout);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MachineListeningTcpResult that)) return false;
        return Objects.equals(stdout, that.stdout);
    }

    @Override
    public int hashCode() { return Objects.hash(stdout); }

    @Override
    public String toString() { return "MachineListeningTcpResult" + toWire(); }

    public static final class Builder {
        private String stdout;
        private boolean stdoutSet;

        public Builder stdout(String value) {
            this.stdout = value;
            this.stdoutSet = true;
            return this;
        }
        public MachineListeningTcpResult build() { return new MachineListeningTcpResult(this); }
    }
}
