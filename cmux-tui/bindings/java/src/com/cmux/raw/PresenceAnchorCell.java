// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class PresenceAnchorCell implements WireValue, PresenceAnchor {
    private final long col;
    private final long row;
    private final Field<UInt64> scrollOffset;

    private PresenceAnchorCell(Builder builder) {
        if (!builder.colSet) throw new IllegalArgumentException("col is required");
        this.col = builder.col;
        if (!builder.rowSet) throw new IllegalArgumentException("row is required");
        this.row = builder.row;
        this.scrollOffset = builder.scrollOffset;
    }

    public static Builder builder() { return new Builder(); }

    public long col() { return col; }
    public String kind() { return "cell"; }
    public long row() { return row; }
    public Field<UInt64> scrollOffset() { return scrollOffset; }

    public static PresenceAnchorCell fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "PresenceAnchorCell");
        Builder builder = builder();
        Object rawCol = Wire.required(object, "col");
        builder.col(Wire.uint32(rawCol, "PresenceAnchorCell.col"));
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "cell", "PresenceAnchorCell.kind");
        Object rawRow = Wire.required(object, "row");
        builder.row(Wire.uint32(rawRow, "PresenceAnchorCell.row"));
        Object rawScrollOffset = Wire.optional(object, "scroll_offset");
        if (!Wire.isMissing(rawScrollOffset)) {
            builder.scrollOffset(Wire.uint64(rawScrollOffset, "PresenceAnchorCell.scroll_offset"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "col", col);
        Wire.put(object, "kind", "cell");
        Wire.put(object, "row", row);
        Wire.put(object, "scroll_offset", scrollOffset);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof PresenceAnchorCell that)) return false;
        return Objects.equals(col, that.col) && Objects.equals(row, that.row) && Objects.equals(scrollOffset, that.scrollOffset);
    }

    @Override
    public int hashCode() { return Objects.hash(col, row, scrollOffset); }

    @Override
    public String toString() { return "PresenceAnchorCell" + toWire(); }

    public static final class Builder {
        private Long col;
        private boolean colSet;
        private Long row;
        private boolean rowSet;
        private Field<UInt64> scrollOffset = Field.omitted();

        public Builder col(long value) {
            this.col = value;
            this.colSet = true;
            return this;
        }
        public Builder row(long value) {
            this.row = value;
            this.rowSet = true;
            return this;
        }
        public Builder scrollOffset(UInt64 value) {
            this.scrollOffset = Field.of(value);
            return this;
        }
        public PresenceAnchorCell build() { return new PresenceAnchorCell(this); }
    }
}
