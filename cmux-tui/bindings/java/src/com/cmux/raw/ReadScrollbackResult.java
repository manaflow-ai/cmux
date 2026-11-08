// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReadScrollbackResult implements WireValue {
    private final UInt64 epoch;
    private final List<RenderRow> rows;
    private final long start;
    private final long total;

    private ReadScrollbackResult(Builder builder) {
        if (!builder.epochSet) throw new IllegalArgumentException("epoch is required");
        this.epoch = Wire.nonNull(builder.epoch, "epoch");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = List.copyOf(Wire.nonNull(builder.rows, "rows"));
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = builder.start;
        if (!builder.totalSet) throw new IllegalArgumentException("total is required");
        this.total = builder.total;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 epoch() { return epoch; }
    public List<RenderRow> rows() { return rows; }
    public long start() { return start; }
    public long total() { return total; }

    public static ReadScrollbackResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReadScrollbackResult");
        Builder builder = builder();
        Object rawEpoch = Wire.required(object, "epoch");
        builder.epoch(Wire.uint64(rawEpoch, "ReadScrollbackResult.epoch"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.array(rawRows, "ReadScrollbackResult.rows", item -> RenderRow.fromWire(item)));
        Object rawStart = Wire.required(object, "start");
        builder.start(Wire.uint32(rawStart, "ReadScrollbackResult.start"));
        Object rawTotal = Wire.required(object, "total");
        builder.total(Wire.uint32(rawTotal, "ReadScrollbackResult.total"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "epoch", epoch);
        Wire.put(object, "rows", rows);
        Wire.put(object, "start", start);
        Wire.put(object, "total", total);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReadScrollbackResult that)) return false;
        return Objects.equals(epoch, that.epoch) && Objects.equals(rows, that.rows) && Objects.equals(start, that.start) && Objects.equals(total, that.total);
    }

    @Override
    public int hashCode() { return Objects.hash(epoch, rows, start, total); }

    @Override
    public String toString() { return "ReadScrollbackResult" + toWire(); }

    public static final class Builder {
        private UInt64 epoch;
        private boolean epochSet;
        private List<RenderRow> rows;
        private boolean rowsSet;
        private Long start;
        private boolean startSet;
        private Long total;
        private boolean totalSet;

        public Builder epoch(UInt64 value) {
            this.epoch = value;
            this.epochSet = true;
            return this;
        }
        public Builder rows(List<RenderRow> value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder start(long value) {
            this.start = value;
            this.startSet = true;
            return this;
        }
        public Builder total(long value) {
            this.total = value;
            this.totalSet = true;
            return this;
        }
        public ReadScrollbackResult build() { return new ReadScrollbackResult(this); }
    }
}
