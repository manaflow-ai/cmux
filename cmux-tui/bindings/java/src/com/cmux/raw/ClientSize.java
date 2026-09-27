// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ClientSize implements WireValue {
    private final Integer cols;
    private final Integer rows;
    private final boolean sizeParticipating;
    private final UInt64 surface;

    private ClientSize(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.sizeParticipatingSet) throw new IllegalArgumentException("size_participating is required");
        this.sizeParticipating = builder.sizeParticipating;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Integer cols() { return cols; }
    public Integer rows() { return rows; }
    public boolean sizeParticipating() { return sizeParticipating; }
    public UInt64 surface() { return surface; }

    public static ClientSize fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ClientSize");
        Builder builder = builder();
        Object rawCols = Wire.required(object, "cols");
        builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "ClientSize.cols"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "ClientSize.rows"));
        Object rawSizeParticipating = Wire.required(object, "size_participating");
        builder.sizeParticipating(Wire.bool(rawSizeParticipating, "ClientSize.size_participating"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "ClientSize.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "rows", rows);
        Wire.put(object, "size_participating", sizeParticipating);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ClientSize that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(rows, that.rows) && Objects.equals(sizeParticipating, that.sizeParticipating) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, rows, sizeParticipating, surface); }

    @Override
    public String toString() { return "ClientSize" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private Integer rows;
        private boolean rowsSet;
        private Boolean sizeParticipating;
        private boolean sizeParticipatingSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder cols(Integer value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder sizeParticipating(boolean value) {
            this.sizeParticipating = value;
            this.sizeParticipatingSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public ClientSize build() { return new ClientSize(this); }
    }
}
