// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class UsageRecordResult implements WireValue {
    private final long written;

    private UsageRecordResult(Builder builder) {
        if (!builder.writtenSet) throw new IllegalArgumentException("written is required");
        this.written = builder.written;
    }

    public static Builder builder() { return new Builder(); }

    public long written() { return written; }

    public static UsageRecordResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UsageRecordResult");
        Builder builder = builder();
        Object rawWritten = Wire.required(object, "written");
        builder.written(Wire.uint32(rawWritten, "UsageRecordResult.written"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "written", written);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UsageRecordResult that)) return false;
        return Objects.equals(written, that.written);
    }

    @Override
    public int hashCode() { return Objects.hash(written); }

    @Override
    public String toString() { return "UsageRecordResult" + toWire(); }

    public static final class Builder {
        private Long written;
        private boolean writtenSet;

        public Builder written(long value) {
            this.written = value;
            this.writtenSet = true;
            return this;
        }
        public UsageRecordResult build() { return new UsageRecordResult(this); }
    }
}
