// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FrontendJournalEventResize implements WireValue, FrontendJournalEvent {
    private final int cellHeight;
    private final int cellWidth;
    private final int cols;
    private final String eventId;
    private final String frontendProjectionId;
    private final String generation;
    private final int rows;

    private FrontendJournalEventResize(Builder builder) {
        if (!builder.cellHeightSet) throw new IllegalArgumentException("cell_height is required");
        this.cellHeight = builder.cellHeight;
        if (!builder.cellWidthSet) throw new IllegalArgumentException("cell_width is required");
        this.cellWidth = builder.cellWidth;
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.eventIdSet) throw new IllegalArgumentException("event_id is required");
        this.eventId = Wire.nonNull(builder.eventId, "event_id");
        if (!builder.frontendProjectionIdSet) throw new IllegalArgumentException("frontend_projection_id is required");
        this.frontendProjectionId = Wire.nonNull(builder.frontendProjectionId, "frontend_projection_id");
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public int cellHeight() { return cellHeight; }
    public int cellWidth() { return cellWidth; }
    public int cols() { return cols; }
    public String eventId() { return eventId; }
    public String frontendProjectionId() { return frontendProjectionId; }
    public String generation() { return generation; }
    public String kind() { return "resize"; }
    public int rows() { return rows; }

    public static FrontendJournalEventResize fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FrontendJournalEventResize");
        Builder builder = builder();
        Object rawCellHeight = Wire.required(object, "cell_height");
        builder.cellHeight(Wire.uint16(rawCellHeight, "FrontendJournalEventResize.cell_height"));
        Object rawCellWidth = Wire.required(object, "cell_width");
        builder.cellWidth(Wire.uint16(rawCellWidth, "FrontendJournalEventResize.cell_width"));
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "FrontendJournalEventResize.cols"));
        Object rawEventId = Wire.required(object, "event_id");
        builder.eventId(Wire.string(rawEventId, "FrontendJournalEventResize.event_id"));
        Object rawFrontendProjectionId = Wire.required(object, "frontend_projection_id");
        builder.frontendProjectionId(Wire.string(rawFrontendProjectionId, "FrontendJournalEventResize.frontend_projection_id"));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.string(rawGeneration, "FrontendJournalEventResize.generation"));
        Object rawKind = Wire.required(object, "kind");
        ProtocolSupport.literal(rawKind, "resize", "FrontendJournalEventResize.kind");
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "FrontendJournalEventResize.rows"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cell_height", cellHeight);
        Wire.put(object, "cell_width", cellWidth);
        Wire.put(object, "cols", cols);
        Wire.put(object, "event_id", eventId);
        Wire.put(object, "frontend_projection_id", frontendProjectionId);
        Wire.put(object, "generation", generation);
        Wire.put(object, "kind", "resize");
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FrontendJournalEventResize that)) return false;
        return Objects.equals(cellHeight, that.cellHeight) && Objects.equals(cellWidth, that.cellWidth) && Objects.equals(cols, that.cols) && Objects.equals(eventId, that.eventId) && Objects.equals(frontendProjectionId, that.frontendProjectionId) && Objects.equals(generation, that.generation) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cellHeight, cellWidth, cols, eventId, frontendProjectionId, generation, rows); }

    @Override
    public String toString() { return "FrontendJournalEventResize" + toWire(); }

    public static final class Builder {
        private Integer cellHeight;
        private boolean cellHeightSet;
        private Integer cellWidth;
        private boolean cellWidthSet;
        private Integer cols;
        private boolean colsSet;
        private String eventId;
        private boolean eventIdSet;
        private String frontendProjectionId;
        private boolean frontendProjectionIdSet;
        private String generation;
        private boolean generationSet;
        private Integer rows;
        private boolean rowsSet;

        public Builder cellHeight(int value) {
            this.cellHeight = value;
            this.cellHeightSet = true;
            return this;
        }
        public Builder cellWidth(int value) {
            this.cellWidth = value;
            this.cellWidthSet = true;
            return this;
        }
        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder eventId(String value) {
            this.eventId = value;
            this.eventIdSet = true;
            return this;
        }
        public Builder frontendProjectionId(String value) {
            this.frontendProjectionId = value;
            this.frontendProjectionIdSet = true;
            return this;
        }
        public Builder generation(String value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public FrontendJournalEventResize build() { return new FrontendJournalEventResize(this); }
    }
}
