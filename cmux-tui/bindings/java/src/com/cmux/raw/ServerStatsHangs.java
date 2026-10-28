// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsHangs implements WireValue {
    private final UInt64 over250ms;
    private final List<ServerStatsHangRecord> records;

    private ServerStatsHangs(Builder builder) {
        if (!builder.over250msSet) throw new IllegalArgumentException("over_250ms is required");
        this.over250ms = Wire.nonNull(builder.over250ms, "over_250ms");
        if (!builder.recordsSet) throw new IllegalArgumentException("records is required");
        this.records = List.copyOf(Wire.nonNull(builder.records, "records"));
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 over250ms() { return over250ms; }
    public List<ServerStatsHangRecord> records() { return records; }

    public static ServerStatsHangs fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsHangs");
        Builder builder = builder();
        Object rawOver250ms = Wire.required(object, "over_250ms");
        builder.over250ms(Wire.uint64(rawOver250ms, "ServerStatsHangs.over_250ms"));
        Object rawRecords = Wire.required(object, "records");
        builder.records(Wire.array(rawRecords, "ServerStatsHangs.records", item -> ServerStatsHangRecord.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "over_250ms", over250ms);
        Wire.put(object, "records", records);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsHangs that)) return false;
        return Objects.equals(over250ms, that.over250ms) && Objects.equals(records, that.records);
    }

    @Override
    public int hashCode() { return Objects.hash(over250ms, records); }

    @Override
    public String toString() { return "ServerStatsHangs" + toWire(); }

    public static final class Builder {
        private UInt64 over250ms;
        private boolean over250msSet;
        private List<ServerStatsHangRecord> records;
        private boolean recordsSet;

        public Builder over250ms(UInt64 value) {
            this.over250ms = value;
            this.over250msSet = true;
            return this;
        }
        public Builder records(List<ServerStatsHangRecord> value) {
            this.records = value;
            this.recordsSet = true;
            return this;
        }
        public ServerStatsHangs build() { return new ServerStatsHangs(this); }
    }
}
