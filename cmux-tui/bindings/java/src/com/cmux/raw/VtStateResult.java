// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class VtStateResult implements WireValue {
    private final int cols;
    private final Bytes data;
    private final Field<KittyGraphicsState> kittyGraphicsState;
    private final Field<List<KittyImageAlias>> kittyImageAliases;
    private final int rows;

    private VtStateResult(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.dataSet) throw new IllegalArgumentException("data is required");
        this.data = Wire.nonNull(builder.data, "data");
        this.kittyGraphicsState = builder.kittyGraphicsState;
        this.kittyImageAliases = builder.kittyImageAliases.map(value -> List.copyOf(value));
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public Bytes data() { return data; }
    public Field<KittyGraphicsState> kittyGraphicsState() { return kittyGraphicsState; }
    public Field<List<KittyImageAlias>> kittyImageAliases() { return kittyImageAliases; }
    public int rows() { return rows; }

    public static VtStateResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "VtStateResult");
        Builder builder = builder();
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "VtStateResult.cols"));
        Object rawData = Wire.required(object, "data");
        builder.data(Wire.bytes(rawData, "VtStateResult.data"));
        Object rawKittyGraphicsState = Wire.optional(object, "kitty_graphics_state");
        if (!Wire.isMissing(rawKittyGraphicsState)) {
            builder.kittyGraphicsState(KittyGraphicsState.fromWire(rawKittyGraphicsState));
        }
        Object rawKittyImageAliases = Wire.optional(object, "kitty_image_aliases");
        if (!Wire.isMissing(rawKittyImageAliases)) {
            builder.kittyImageAliases(Wire.array(rawKittyImageAliases, "VtStateResult.kitty_image_aliases", item -> KittyImageAlias.fromWire(item)));
        }
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "VtStateResult.rows"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "data", data);
        Wire.put(object, "kitty_graphics_state", kittyGraphicsState);
        Wire.put(object, "kitty_image_aliases", kittyImageAliases);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof VtStateResult that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(data, that.data) && Objects.equals(kittyGraphicsState, that.kittyGraphicsState) && Objects.equals(kittyImageAliases, that.kittyImageAliases) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, data, kittyGraphicsState, kittyImageAliases, rows); }

    @Override
    public String toString() { return "VtStateResult" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private Bytes data;
        private boolean dataSet;
        private Field<KittyGraphicsState> kittyGraphicsState = Field.omitted();
        private Field<List<KittyImageAlias>> kittyImageAliases = Field.omitted();
        private Integer rows;
        private boolean rowsSet;

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder data(Bytes value) {
            this.data = value;
            this.dataSet = true;
            return this;
        }
        public Builder kittyGraphicsState(KittyGraphicsState value) {
            this.kittyGraphicsState = Field.of(value);
            return this;
        }
        public Builder kittyImageAliases(List<KittyImageAlias> value) {
            this.kittyImageAliases = Field.of(value);
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public VtStateResult build() { return new VtStateResult(this); }
    }
}
