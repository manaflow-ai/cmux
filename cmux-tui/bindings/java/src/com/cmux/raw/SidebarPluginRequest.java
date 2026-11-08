// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable sidebar-plugin request. Protocol v6; authority: frontend. */
public final class SidebarPluginRequest implements WireValue {
    private final int cols;
    private final Field<Boolean> relaunch;
    private final int rows;

    private SidebarPluginRequest(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        this.relaunch = builder.relaunch;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public Field<Boolean> relaunch() { return relaunch; }
    public int rows() { return rows; }

    public static SidebarPluginRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SidebarPluginRequest");
        Builder builder = builder();
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "SidebarPluginRequest.cols"));
        Object rawRelaunch = Wire.optional(object, "relaunch");
        if (!Wire.isMissing(rawRelaunch)) {
            builder.relaunch(Wire.bool(rawRelaunch, "SidebarPluginRequest.relaunch"));
        }
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "SidebarPluginRequest.rows"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "relaunch", relaunch);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SidebarPluginRequest that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(relaunch, that.relaunch) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, relaunch, rows); }

    @Override
    public String toString() { return "SidebarPluginRequest" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private Field<Boolean> relaunch = Field.omitted();
        private Integer rows;
        private boolean rowsSet;

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder relaunch(Boolean value) {
            this.relaunch = Field.of(value);
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public SidebarPluginRequest build() { return new SidebarPluginRequest(this); }
    }
}
