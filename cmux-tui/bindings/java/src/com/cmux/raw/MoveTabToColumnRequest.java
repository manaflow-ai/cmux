// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-to-column request. Protocol v12; authority: control. */
public final class MoveTabToColumnRequest implements WireValue {
    private final Field<UInt64> afterColumn;
    private final Field<ColumnPin> dock;
    private final Field<UInt64> pane;
    private final Field<SplitRespawn> respawn;
    private final Field<UInt64> screen;
    private final UInt64 surface;
    private final Field<String> transaction;
    private final Field<Double> width;

    private MoveTabToColumnRequest(Builder builder) {
        this.afterColumn = builder.afterColumn;
        this.dock = builder.dock;
        this.pane = builder.pane;
        this.respawn = builder.respawn;
        this.screen = builder.screen;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.transaction = builder.transaction;
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> afterColumn() { return afterColumn; }
    public Field<ColumnPin> dock() { return dock; }
    public Field<UInt64> pane() { return pane; }
    public Field<SplitRespawn> respawn() { return respawn; }
    public Field<UInt64> screen() { return screen; }
    public UInt64 surface() { return surface; }
    public Field<String> transaction() { return transaction; }
    public Field<Double> width() { return width; }

    public static MoveTabToColumnRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabToColumnRequest");
        Builder builder = builder();
        Object rawAfterColumn = Wire.optional(object, "after_column");
        if (!Wire.isMissing(rawAfterColumn)) {
            builder.afterColumn(rawAfterColumn == null ? null : Wire.uint64(rawAfterColumn, "MoveTabToColumnRequest.after_column"));
        }
        Object rawDock = Wire.optional(object, "dock");
        if (!Wire.isMissing(rawDock)) {
            builder.dock(rawDock == null ? null : ColumnPin.fromWire(rawDock));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "MoveTabToColumnRequest.pane"));
        }
        Object rawRespawn = Wire.optional(object, "respawn");
        if (!Wire.isMissing(rawRespawn)) {
            builder.respawn(rawRespawn == null ? null : SplitRespawn.fromWire(rawRespawn));
        }
        Object rawScreen = Wire.optional(object, "screen");
        if (!Wire.isMissing(rawScreen)) {
            builder.screen(rawScreen == null ? null : Wire.uint64(rawScreen, "MoveTabToColumnRequest.screen"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MoveTabToColumnRequest.surface"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "MoveTabToColumnRequest.transaction"));
        }
        Object rawWidth = Wire.optional(object, "width");
        if (!Wire.isMissing(rawWidth)) {
            builder.width(rawWidth == null ? null : Wire.float64(rawWidth, "MoveTabToColumnRequest.width"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_column", afterColumn);
        Wire.put(object, "dock", dock);
        Wire.put(object, "pane", pane);
        Wire.put(object, "respawn", respawn);
        Wire.put(object, "screen", screen);
        Wire.put(object, "surface", surface);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabToColumnRequest that)) return false;
        return Objects.equals(afterColumn, that.afterColumn) && Objects.equals(dock, that.dock) && Objects.equals(pane, that.pane) && Objects.equals(respawn, that.respawn) && Objects.equals(screen, that.screen) && Objects.equals(surface, that.surface) && Objects.equals(transaction, that.transaction) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(afterColumn, dock, pane, respawn, screen, surface, transaction, width); }

    @Override
    public String toString() { return "MoveTabToColumnRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> afterColumn = Field.omitted();
        private Field<ColumnPin> dock = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<SplitRespawn> respawn = Field.omitted();
        private Field<UInt64> screen = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> transaction = Field.omitted();
        private Field<Double> width = Field.omitted();

        public Builder afterColumn(UInt64 value) {
            this.afterColumn = Field.ofNullable(value);
            return this;
        }
        public Builder dock(ColumnPin value) {
            this.dock = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder respawn(SplitRespawn value) {
            this.respawn = Field.ofNullable(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = Field.ofNullable(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public Builder width(Double value) {
            this.width = Field.ofNullable(value);
            return this;
        }
        public MoveTabToColumnRequest build() { return new MoveTabToColumnRequest(this); }
    }
}
