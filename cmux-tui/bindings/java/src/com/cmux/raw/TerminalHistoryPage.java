// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalHistoryPage implements WireValue {
    private final String data;
    private final UInt64 marker;
    private final int rows;

    private TerminalHistoryPage(Builder builder) {
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        if (!builder.markerSet) throw new IllegalArgumentException("marker is required");
        this.marker = Wire.nonNull(builder.marker, "marker");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public String data() { return data; }
    public UInt64 marker() { return marker; }
    public int rows() { return rows; }

    public static TerminalHistoryPage fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalHistoryPage");
        Builder builder = builder();
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.string(rawData, "TerminalHistoryPage.data"));
        Object rawMarker = Wire.required(object, "marker");
        builder.marker(Wire.uint64(rawMarker, "TerminalHistoryPage.marker"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "TerminalHistoryPage.rows"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "data", data);
        Wire.put(object, "marker", marker);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalHistoryPage that)) return false;
        return Objects.equals(data, that.data) && Objects.equals(marker, that.marker) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(data, marker, rows); }

    @Override
    public String toString() { return "TerminalHistoryPage" + toWire(); }

    public static final class Builder {
        private String data;
        private boolean dataSet;
        private UInt64 marker;
        private boolean markerSet;
        private Integer rows;
        private boolean rowsSet;

        public Builder data(String value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder marker(UInt64 value) {
            this.marker = value;
            this.markerSet = true;
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public TerminalHistoryPage build() { return new TerminalHistoryPage(this); }
    }
}
