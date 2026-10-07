// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-group-to-column request. Protocol v12; authority: control. */
public final class MoveTabGroupToColumnRequest implements WireValue {
    private final Field<UInt64> afterColumn;
    private final String group;
    private final Field<Object> pane;
    private final Field<UInt64> screen;
    private final Field<String> transaction;
    private final Field<Double> width;

    private MoveTabGroupToColumnRequest(Builder builder) {
        this.afterColumn = builder.afterColumn;
        if (!builder.groupSet) throw new IllegalArgumentException("group is required");
        this.group = Wire.nonNull(builder.group, "group");
        this.pane = builder.pane;
        this.screen = builder.screen;
        this.transaction = builder.transaction;
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> afterColumn() { return afterColumn; }
    public String group() { return group; }
    public Field<Object> pane() { return pane; }
    public Field<UInt64> screen() { return screen; }
    public Field<String> transaction() { return transaction; }
    public Field<Double> width() { return width; }

    public static MoveTabGroupToColumnRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabGroupToColumnRequest");
        Builder builder = builder();
        Object rawAfterColumn = Wire.optional(object, "after_column");
        if (!Wire.isMissing(rawAfterColumn)) {
            builder.afterColumn(rawAfterColumn == null ? null : Wire.uint64(rawAfterColumn, "MoveTabGroupToColumnRequest.after_column"));
        }
        Object rawGroup = Wire.required(object, "group");
        builder.group(Wire.string(rawGroup, "MoveTabGroupToColumnRequest.group"));
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.immutableJson(rawPane));
        }
        Object rawScreen = Wire.optional(object, "screen");
        if (!Wire.isMissing(rawScreen)) {
            builder.screen(rawScreen == null ? null : Wire.uint64(rawScreen, "MoveTabGroupToColumnRequest.screen"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "MoveTabGroupToColumnRequest.transaction"));
        }
        Object rawWidth = Wire.optional(object, "width");
        if (!Wire.isMissing(rawWidth)) {
            builder.width(rawWidth == null ? null : Wire.float64(rawWidth, "MoveTabGroupToColumnRequest.width"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after_column", afterColumn);
        Wire.put(object, "group", group);
        Wire.put(object, "pane", pane);
        Wire.put(object, "screen", screen);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabGroupToColumnRequest that)) return false;
        return Objects.equals(afterColumn, that.afterColumn) && Objects.equals(group, that.group) && Objects.equals(pane, that.pane) && Objects.equals(screen, that.screen) && Objects.equals(transaction, that.transaction) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(afterColumn, group, pane, screen, transaction, width); }

    @Override
    public String toString() { return "MoveTabGroupToColumnRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> afterColumn = Field.omitted();
        private String group;
        private boolean groupSet;
        private Field<Object> pane = Field.omitted();
        private Field<UInt64> screen = Field.omitted();
        private Field<String> transaction = Field.omitted();
        private Field<Double> width = Field.omitted();

        public Builder afterColumn(UInt64 value) {
            this.afterColumn = Field.ofNullable(value);
            return this;
        }
        public Builder group(String value) {
            this.group = value;
            this.groupSet = true;
            return this;
        }
        public Builder pane(Object value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder screen(UInt64 value) {
            this.screen = Field.ofNullable(value);
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
        public MoveTabGroupToColumnRequest build() { return new MoveTabGroupToColumnRequest(this); }
    }
}
