// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class RenderGraphicPlacement implements WireValue {
    private final Field<Integer> anchorCol;
    private final Field<Long> anchorRow;
    private final long columns;
    private final long gridCols;
    private final long gridRows;
    private final long imageId;
    private final long ordinal;
    private final long pixelHeight;
    private final long pixelWidth;
    private final long placementId;
    private final long rows;
    private final long sourceHeight;
    private final long sourceWidth;
    private final long sourceX;
    private final long sourceY;
    private final int viewportCol;
    private final int viewportRow;
    private final boolean viewportVisible;
    private final long xOffset;
    private final long yOffset;
    private final int z;

    private RenderGraphicPlacement(Builder builder) {
        this.anchorCol = builder.anchorCol;
        this.anchorRow = builder.anchorRow;
        if (!builder.columnsSet) throw new IllegalArgumentException("columns is required");
        this.columns = builder.columns;
        if (!builder.gridColsSet) throw new IllegalArgumentException("grid_cols is required");
        this.gridCols = builder.gridCols;
        if (!builder.gridRowsSet) throw new IllegalArgumentException("grid_rows is required");
        this.gridRows = builder.gridRows;
        if (!builder.imageIdSet) throw new IllegalArgumentException("image_id is required");
        this.imageId = builder.imageId;
        if (!builder.ordinalSet) throw new IllegalArgumentException("ordinal is required");
        this.ordinal = builder.ordinal;
        if (!builder.pixelHeightSet) throw new IllegalArgumentException("pixel_height is required");
        this.pixelHeight = builder.pixelHeight;
        if (!builder.pixelWidthSet) throw new IllegalArgumentException("pixel_width is required");
        this.pixelWidth = builder.pixelWidth;
        if (!builder.placementIdSet) throw new IllegalArgumentException("placement_id is required");
        this.placementId = builder.placementId;
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
        if (!builder.sourceHeightSet) throw new IllegalArgumentException("source_height is required");
        this.sourceHeight = builder.sourceHeight;
        if (!builder.sourceWidthSet) throw new IllegalArgumentException("source_width is required");
        this.sourceWidth = builder.sourceWidth;
        if (!builder.sourceXSet) throw new IllegalArgumentException("source_x is required");
        this.sourceX = builder.sourceX;
        if (!builder.sourceYSet) throw new IllegalArgumentException("source_y is required");
        this.sourceY = builder.sourceY;
        if (!builder.viewportColSet) throw new IllegalArgumentException("viewport_col is required");
        this.viewportCol = builder.viewportCol;
        if (!builder.viewportRowSet) throw new IllegalArgumentException("viewport_row is required");
        this.viewportRow = builder.viewportRow;
        if (!builder.viewportVisibleSet) throw new IllegalArgumentException("viewport_visible is required");
        this.viewportVisible = builder.viewportVisible;
        if (!builder.xOffsetSet) throw new IllegalArgumentException("x_offset is required");
        this.xOffset = builder.xOffset;
        if (!builder.yOffsetSet) throw new IllegalArgumentException("y_offset is required");
        this.yOffset = builder.yOffset;
        if (!builder.zSet) throw new IllegalArgumentException("z is required");
        this.z = builder.z;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> anchorCol() { return anchorCol; }
    public Field<Long> anchorRow() { return anchorRow; }
    public long columns() { return columns; }
    public long gridCols() { return gridCols; }
    public long gridRows() { return gridRows; }
    public long imageId() { return imageId; }
    public long ordinal() { return ordinal; }
    public long pixelHeight() { return pixelHeight; }
    public long pixelWidth() { return pixelWidth; }
    public long placementId() { return placementId; }
    public long rows() { return rows; }
    public long sourceHeight() { return sourceHeight; }
    public long sourceWidth() { return sourceWidth; }
    public long sourceX() { return sourceX; }
    public long sourceY() { return sourceY; }
    public int viewportCol() { return viewportCol; }
    public int viewportRow() { return viewportRow; }
    public boolean viewportVisible() { return viewportVisible; }
    public long xOffset() { return xOffset; }
    public long yOffset() { return yOffset; }
    public int z() { return z; }

    public static RenderGraphicPlacement fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "RenderGraphicPlacement");
        Builder builder = builder();
        Object rawAnchorCol = Wire.optional(object, "anchor_col");
        if (!Wire.isMissing(rawAnchorCol)) {
            builder.anchorCol(Wire.uint16(rawAnchorCol, "RenderGraphicPlacement.anchor_col"));
        }
        Object rawAnchorRow = Wire.optional(object, "anchor_row");
        if (!Wire.isMissing(rawAnchorRow)) {
            builder.anchorRow(Wire.uint32(rawAnchorRow, "RenderGraphicPlacement.anchor_row"));
        }
        Object rawColumns = Wire.required(object, "columns");
        builder.columns(Wire.uint32(rawColumns, "RenderGraphicPlacement.columns"));
        Object rawGridCols = Wire.required(object, "grid_cols");
        builder.gridCols(Wire.uint32(rawGridCols, "RenderGraphicPlacement.grid_cols"));
        Object rawGridRows = Wire.required(object, "grid_rows");
        builder.gridRows(Wire.uint32(rawGridRows, "RenderGraphicPlacement.grid_rows"));
        Object rawImageId = Wire.required(object, "image_id");
        builder.imageId(Wire.uint32(rawImageId, "RenderGraphicPlacement.image_id"));
        Object rawOrdinal = Wire.required(object, "ordinal");
        builder.ordinal(Wire.uint32(rawOrdinal, "RenderGraphicPlacement.ordinal"));
        Object rawPixelHeight = Wire.required(object, "pixel_height");
        builder.pixelHeight(Wire.uint32(rawPixelHeight, "RenderGraphicPlacement.pixel_height"));
        Object rawPixelWidth = Wire.required(object, "pixel_width");
        builder.pixelWidth(Wire.uint32(rawPixelWidth, "RenderGraphicPlacement.pixel_width"));
        Object rawPlacementId = Wire.required(object, "placement_id");
        builder.placementId(Wire.uint32(rawPlacementId, "RenderGraphicPlacement.placement_id"));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint32(rawRows, "RenderGraphicPlacement.rows"));
        Object rawSourceHeight = Wire.required(object, "source_height");
        builder.sourceHeight(Wire.uint32(rawSourceHeight, "RenderGraphicPlacement.source_height"));
        Object rawSourceWidth = Wire.required(object, "source_width");
        builder.sourceWidth(Wire.uint32(rawSourceWidth, "RenderGraphicPlacement.source_width"));
        Object rawSourceX = Wire.required(object, "source_x");
        builder.sourceX(Wire.uint32(rawSourceX, "RenderGraphicPlacement.source_x"));
        Object rawSourceY = Wire.required(object, "source_y");
        builder.sourceY(Wire.uint32(rawSourceY, "RenderGraphicPlacement.source_y"));
        Object rawViewportCol = Wire.required(object, "viewport_col");
        builder.viewportCol(Wire.int32(rawViewportCol, "RenderGraphicPlacement.viewport_col"));
        Object rawViewportRow = Wire.required(object, "viewport_row");
        builder.viewportRow(Wire.int32(rawViewportRow, "RenderGraphicPlacement.viewport_row"));
        Object rawViewportVisible = Wire.required(object, "viewport_visible");
        builder.viewportVisible(Wire.bool(rawViewportVisible, "RenderGraphicPlacement.viewport_visible"));
        Object rawXOffset = Wire.required(object, "x_offset");
        builder.xOffset(Wire.uint32(rawXOffset, "RenderGraphicPlacement.x_offset"));
        Object rawYOffset = Wire.required(object, "y_offset");
        builder.yOffset(Wire.uint32(rawYOffset, "RenderGraphicPlacement.y_offset"));
        Object rawZ = Wire.required(object, "z");
        builder.z(Wire.int32(rawZ, "RenderGraphicPlacement.z"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "anchor_col", anchorCol);
        Wire.put(object, "anchor_row", anchorRow);
        Wire.put(object, "columns", columns);
        Wire.put(object, "grid_cols", gridCols);
        Wire.put(object, "grid_rows", gridRows);
        Wire.put(object, "image_id", imageId);
        Wire.put(object, "ordinal", ordinal);
        Wire.put(object, "pixel_height", pixelHeight);
        Wire.put(object, "pixel_width", pixelWidth);
        Wire.put(object, "placement_id", placementId);
        Wire.put(object, "rows", rows);
        Wire.put(object, "source_height", sourceHeight);
        Wire.put(object, "source_width", sourceWidth);
        Wire.put(object, "source_x", sourceX);
        Wire.put(object, "source_y", sourceY);
        Wire.put(object, "viewport_col", viewportCol);
        Wire.put(object, "viewport_row", viewportRow);
        Wire.put(object, "viewport_visible", viewportVisible);
        Wire.put(object, "x_offset", xOffset);
        Wire.put(object, "y_offset", yOffset);
        Wire.put(object, "z", z);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof RenderGraphicPlacement that)) return false;
        return Objects.equals(anchorCol, that.anchorCol) && Objects.equals(anchorRow, that.anchorRow) && Objects.equals(columns, that.columns) && Objects.equals(gridCols, that.gridCols) && Objects.equals(gridRows, that.gridRows) && Objects.equals(imageId, that.imageId) && Objects.equals(ordinal, that.ordinal) && Objects.equals(pixelHeight, that.pixelHeight) && Objects.equals(pixelWidth, that.pixelWidth) && Objects.equals(placementId, that.placementId) && Objects.equals(rows, that.rows) && Objects.equals(sourceHeight, that.sourceHeight) && Objects.equals(sourceWidth, that.sourceWidth) && Objects.equals(sourceX, that.sourceX) && Objects.equals(sourceY, that.sourceY) && Objects.equals(viewportCol, that.viewportCol) && Objects.equals(viewportRow, that.viewportRow) && Objects.equals(viewportVisible, that.viewportVisible) && Objects.equals(xOffset, that.xOffset) && Objects.equals(yOffset, that.yOffset) && Objects.equals(z, that.z);
    }

    @Override
    public int hashCode() { return Objects.hash(anchorCol, anchorRow, columns, gridCols, gridRows, imageId, ordinal, pixelHeight, pixelWidth, placementId, rows, sourceHeight, sourceWidth, sourceX, sourceY, viewportCol, viewportRow, viewportVisible, xOffset, yOffset, z); }

    @Override
    public String toString() { return "RenderGraphicPlacement" + toWire(); }

    public static final class Builder {
        private Field<Integer> anchorCol = Field.omitted();
        private Field<Long> anchorRow = Field.omitted();
        private Long columns;
        private boolean columnsSet;
        private Long gridCols;
        private boolean gridColsSet;
        private Long gridRows;
        private boolean gridRowsSet;
        private Long imageId;
        private boolean imageIdSet;
        private Long ordinal;
        private boolean ordinalSet;
        private Long pixelHeight;
        private boolean pixelHeightSet;
        private Long pixelWidth;
        private boolean pixelWidthSet;
        private Long placementId;
        private boolean placementIdSet;
        private Long rows;
        private boolean rowsSet;
        private Long sourceHeight;
        private boolean sourceHeightSet;
        private Long sourceWidth;
        private boolean sourceWidthSet;
        private Long sourceX;
        private boolean sourceXSet;
        private Long sourceY;
        private boolean sourceYSet;
        private Integer viewportCol;
        private boolean viewportColSet;
        private Integer viewportRow;
        private boolean viewportRowSet;
        private Boolean viewportVisible;
        private boolean viewportVisibleSet;
        private Long xOffset;
        private boolean xOffsetSet;
        private Long yOffset;
        private boolean yOffsetSet;
        private Integer z;
        private boolean zSet;

        public Builder anchorCol(Integer value) {
            this.anchorCol = Field.of(value);
            return this;
        }
        public Builder anchorRow(Long value) {
            this.anchorRow = Field.of(value);
            return this;
        }
        public Builder columns(long value) {
            this.columns = value;
            this.columnsSet = true;
            return this;
        }
        public Builder gridCols(long value) {
            this.gridCols = value;
            this.gridColsSet = true;
            return this;
        }
        public Builder gridRows(long value) {
            this.gridRows = value;
            this.gridRowsSet = true;
            return this;
        }
        public Builder imageId(long value) {
            this.imageId = value;
            this.imageIdSet = true;
            return this;
        }
        public Builder ordinal(long value) {
            this.ordinal = value;
            this.ordinalSet = true;
            return this;
        }
        public Builder pixelHeight(long value) {
            this.pixelHeight = value;
            this.pixelHeightSet = true;
            return this;
        }
        public Builder pixelWidth(long value) {
            this.pixelWidth = value;
            this.pixelWidthSet = true;
            return this;
        }
        public Builder placementId(long value) {
            this.placementId = value;
            this.placementIdSet = true;
            return this;
        }
        public Builder rows(long value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public Builder sourceHeight(long value) {
            this.sourceHeight = value;
            this.sourceHeightSet = true;
            return this;
        }
        public Builder sourceWidth(long value) {
            this.sourceWidth = value;
            this.sourceWidthSet = true;
            return this;
        }
        public Builder sourceX(long value) {
            this.sourceX = value;
            this.sourceXSet = true;
            return this;
        }
        public Builder sourceY(long value) {
            this.sourceY = value;
            this.sourceYSet = true;
            return this;
        }
        public Builder viewportCol(int value) {
            this.viewportCol = value;
            this.viewportColSet = true;
            return this;
        }
        public Builder viewportRow(int value) {
            this.viewportRow = value;
            this.viewportRowSet = true;
            return this;
        }
        public Builder viewportVisible(boolean value) {
            this.viewportVisible = value;
            this.viewportVisibleSet = true;
            return this;
        }
        public Builder xOffset(long value) {
            this.xOffset = value;
            this.xOffsetSet = true;
            return this;
        }
        public Builder yOffset(long value) {
            this.yOffset = value;
            this.yOffsetSet = true;
            return this;
        }
        public Builder z(int value) {
            this.z = value;
            this.zSet = true;
            return this;
        }
        public RenderGraphicPlacement build() { return new RenderGraphicPlacement(this); }
    }
}
