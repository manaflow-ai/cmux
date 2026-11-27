// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class LayoutColumnNode implements WireValue {
    /** dock-columns-v1: the viewport edge the column is pinned to. */
    private final Field<ColumnDock> dock;
    private final UInt64 id;
    private final Layout layout;
    /** rows-v1: only for a column with two or more rows. */
    private final Field<List<LayoutRowNode>> rows;
    private final double width;

    private LayoutColumnNode(Builder builder) {
        this.dock = builder.dock;
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.layoutSet) throw new IllegalArgumentException("layout is required");
        this.layout = Wire.nonNull(builder.layout, "layout");
        this.rows = builder.rows.map(value -> List.copyOf(value));
        if (!builder.widthSet) throw new IllegalArgumentException("width is required");
        this.width = builder.width;
    }

    public static Builder builder() { return new Builder(); }

    public Field<ColumnDock> dock() { return dock; }
    public UInt64 id() { return id; }
    public Layout layout() { return layout; }
    public Field<List<LayoutRowNode>> rows() { return rows; }
    public double width() { return width; }

    public static LayoutColumnNode fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LayoutColumnNode");
        Builder builder = builder();
        Object rawDock = Wire.optional(object, "dock");
        if (!Wire.isMissing(rawDock)) {
            builder.dock(ColumnDock.fromWire(rawDock));
        }
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.uint64(rawId, "LayoutColumnNode.id"));
        Object rawLayout = Wire.required(object, "layout");
        builder.layout(Layout.fromWire(rawLayout));
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(Wire.array(rawRows, "LayoutColumnNode.rows", item -> LayoutRowNode.fromWire(item)));
        }
        Object rawWidth = Wire.required(object, "width");
        builder.width(Wire.float64(rawWidth, "LayoutColumnNode.width"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "dock", dock);
        Wire.put(object, "id", id);
        Wire.put(object, "layout", layout);
        Wire.put(object, "rows", rows);
        Wire.put(object, "width", width);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LayoutColumnNode that)) return false;
        return Objects.equals(dock, that.dock) && Objects.equals(id, that.id) && Objects.equals(layout, that.layout) && Objects.equals(rows, that.rows) && Objects.equals(width, that.width);
    }

    @Override
    public int hashCode() { return Objects.hash(dock, id, layout, rows, width); }

    @Override
    public String toString() { return "LayoutColumnNode" + toWire(); }

    public static final class Builder {
        private Field<ColumnDock> dock = Field.omitted();
        private UInt64 id;
        private boolean idSet;
        private Layout layout;
        private boolean layoutSet;
        private Field<List<LayoutRowNode>> rows = Field.omitted();
        private Double width;
        private boolean widthSet;

        public Builder dock(ColumnDock value) {
            this.dock = Field.of(value);
            return this;
        }
        public Builder id(UInt64 value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder layout(Layout value) {
            this.layout = value;
            this.layoutSet = true;
            return this;
        }
        public Builder rows(List<LayoutRowNode> value) {
            this.rows = Field.of(value);
            return this;
        }
        public Builder width(double value) {
            this.width = value;
            this.widthSet = true;
            return this;
        }
        public LayoutColumnNode build() { return new LayoutColumnNode(this); }
    }
}
