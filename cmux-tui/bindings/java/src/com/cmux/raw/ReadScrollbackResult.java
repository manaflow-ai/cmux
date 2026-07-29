// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.generated;


import com.cmux.Bytes;
import com.cmux.Field;
import com.cmux.UInt64;
import com.cmux.Wire;
import com.cmux.WireEnum;
import com.cmux.WireValue;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ReadScrollbackResult implements WireValue {
    private final List<RenderRow> rows;
    private final long start;
    private final long total;

    private ReadScrollbackResult(Builder builder) {
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = List.copyOf(Wire.nonNull(builder.rows, "rows"));
        if (!builder.startSet) throw new IllegalArgumentException("start is required");
        this.start = builder.start;
        if (!builder.totalSet) throw new IllegalArgumentException("total is required");
        this.total = builder.total;
    }

    public static Builder builder() { return new Builder(); }

    public List<RenderRow> rows() { return rows; }
    public long start() { return start; }
    public long total() { return total; }

    public static ReadScrollbackResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReadScrollbackResult");
        Builder builder = builder();
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
        Wire.put(object, "rows", rows);
        Wire.put(object, "start", start);
        Wire.put(object, "total", total);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReadScrollbackResult that)) return false;
        return Objects.equals(rows, that.rows) && Objects.equals(start, that.start) && Objects.equals(total, that.total);
    }

    @Override
    public int hashCode() { return Objects.hash(rows, start, total); }

    @Override
    public String toString() { return "ReadScrollbackResult" + toWire(); }

    public static final class Builder {
        private List<RenderRow> rows;
        private boolean rowsSet;
        private Long start;
        private boolean startSet;
        private Long total;
        private boolean totalSet;

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
