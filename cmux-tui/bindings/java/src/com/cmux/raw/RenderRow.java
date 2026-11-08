// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RenderRow implements WireValue {
    private final long row;
    private final List<RenderRun> runs;

    private RenderRow(Builder builder) {
        if (!builder.rowSet) throw new IllegalArgumentException("row is required");
        this.row = builder.row;
        if (!builder.runsSet) throw new IllegalArgumentException("runs is required");
        this.runs = List.copyOf(Wire.nonNull(builder.runs, "runs"));
    }

    public static Builder builder() { return new Builder(); }

    public long row() { return row; }
    public List<RenderRun> runs() { return runs; }

    public static RenderRow fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderRow");
        Builder builder = builder();
        Object rawRow = Wire.required(object, "row");
        builder.row(Wire.uint32(rawRow, "RenderRow.row"));
        Object rawRuns = Wire.required(object, "runs");
        builder.runs(Wire.array(rawRuns, "RenderRow.runs", item -> RenderRun.fromWire(item)));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "row", row);
        Wire.put(object, "runs", runs);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenderRow that)) return false;
        return Objects.equals(row, that.row) && Objects.equals(runs, that.runs);
    }

    @Override
    public int hashCode() { return Objects.hash(row, runs); }

    @Override
    public String toString() { return "RenderRow" + toWire(); }

    public static final class Builder {
        private Long row;
        private boolean rowSet;
        private List<RenderRun> runs;
        private boolean runsSet;

        public Builder row(long value) {
            this.row = value;
            this.rowSet = true;
            return this;
        }
        public Builder runs(List<RenderRun> value) {
            this.runs = value;
            this.runsSet = true;
            return this;
        }
        public RenderRow build() { return new RenderRow(this); }
    }
}
