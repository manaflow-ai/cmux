// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ServerStatsMemoryJournalRing implements WireValue {
    private final UInt64 maxEstimateBytes;
    private final UInt64 maxRecords;
    private final UInt64 records;
    private final UInt64 residentEstimateBytes;

    private ServerStatsMemoryJournalRing(Builder builder) {
        if (!builder.maxEstimateBytesSet) throw new IllegalArgumentException("max_estimate_bytes is required");
        this.maxEstimateBytes = Wire.nonNull(builder.maxEstimateBytes, "max_estimate_bytes");
        if (!builder.maxRecordsSet) throw new IllegalArgumentException("max_records is required");
        this.maxRecords = Wire.nonNull(builder.maxRecords, "max_records");
        if (!builder.recordsSet) throw new IllegalArgumentException("records is required");
        this.records = Wire.nonNull(builder.records, "records");
        if (!builder.residentEstimateBytesSet) throw new IllegalArgumentException("resident_estimate_bytes is required");
        this.residentEstimateBytes = Wire.nonNull(builder.residentEstimateBytes, "resident_estimate_bytes");
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 maxEstimateBytes() { return maxEstimateBytes; }
    public UInt64 maxRecords() { return maxRecords; }
    public UInt64 records() { return records; }
    public UInt64 residentEstimateBytes() { return residentEstimateBytes; }

    public static ServerStatsMemoryJournalRing fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ServerStatsMemoryJournalRing");
        Builder builder = builder();
        Object rawMaxEstimateBytes = Wire.required(object, "max_estimate_bytes");
        builder.maxEstimateBytes(Wire.uint64(rawMaxEstimateBytes, "ServerStatsMemoryJournalRing.max_estimate_bytes"));
        Object rawMaxRecords = Wire.required(object, "max_records");
        builder.maxRecords(Wire.uint64(rawMaxRecords, "ServerStatsMemoryJournalRing.max_records"));
        Object rawRecords = Wire.required(object, "records");
        builder.records(Wire.uint64(rawRecords, "ServerStatsMemoryJournalRing.records"));
        Object rawResidentEstimateBytes = Wire.required(object, "resident_estimate_bytes");
        builder.residentEstimateBytes(Wire.uint64(rawResidentEstimateBytes, "ServerStatsMemoryJournalRing.resident_estimate_bytes"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "max_estimate_bytes", maxEstimateBytes);
        Wire.put(object, "max_records", maxRecords);
        Wire.put(object, "records", records);
        Wire.put(object, "resident_estimate_bytes", residentEstimateBytes);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ServerStatsMemoryJournalRing that)) return false;
        return Objects.equals(maxEstimateBytes, that.maxEstimateBytes) && Objects.equals(maxRecords, that.maxRecords) && Objects.equals(records, that.records) && Objects.equals(residentEstimateBytes, that.residentEstimateBytes);
    }

    @Override
    public int hashCode() { return Objects.hash(maxEstimateBytes, maxRecords, records, residentEstimateBytes); }

    @Override
    public String toString() { return "ServerStatsMemoryJournalRing" + toWire(); }

    public static final class Builder {
        private UInt64 maxEstimateBytes;
        private boolean maxEstimateBytesSet;
        private UInt64 maxRecords;
        private boolean maxRecordsSet;
        private UInt64 records;
        private boolean recordsSet;
        private UInt64 residentEstimateBytes;
        private boolean residentEstimateBytesSet;

        public Builder maxEstimateBytes(UInt64 value) {
            this.maxEstimateBytes = value;
            this.maxEstimateBytesSet = true;
            return this;
        }
        public Builder maxRecords(UInt64 value) {
            this.maxRecords = value;
            this.maxRecordsSet = true;
            return this;
        }
        public Builder records(UInt64 value) {
            this.records = value;
            this.recordsSet = true;
            return this;
        }
        public Builder residentEstimateBytes(UInt64 value) {
            this.residentEstimateBytes = value;
            this.residentEstimateBytesSet = true;
            return this;
        }
        public ServerStatsMemoryJournalRing build() { return new ServerStatsMemoryJournalRing(this); }
    }
}
