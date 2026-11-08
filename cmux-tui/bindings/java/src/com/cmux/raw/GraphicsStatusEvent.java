// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable graphics-status event. Protocol v10; streams: subscribe. */
public final class GraphicsStatusEvent implements WireValue, DeltaStreamEvent, ProtocolEvent, SubscribeEvent {
    private final Field<Integer> attempts;
    private final Field<Integer> cellHeight;
    private final Field<Integer> cellWidth;
    private final Field<String> error;
    private final GraphicsStatusEventKind kind;
    private final Field<UInt64> remaining;
    private final Field<Boolean> retryExhausted;
    private final Field<String> summary;

    private GraphicsStatusEvent(Builder builder) {
        this.attempts = builder.attempts;
        this.cellHeight = builder.cellHeight;
        this.cellWidth = builder.cellWidth;
        this.error = builder.error;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.remaining = builder.remaining;
        this.retryExhausted = builder.retryExhausted;
        this.summary = builder.summary;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Integer> attempts() { return attempts; }
    public Field<Integer> cellHeight() { return cellHeight; }
    public Field<Integer> cellWidth() { return cellWidth; }
    public Field<String> error() { return error; }
    public GraphicsStatusEventKind kind() { return kind; }
    public Field<UInt64> remaining() { return remaining; }
    public Field<Boolean> retryExhausted() { return retryExhausted; }
    public Field<String> summary() { return summary; }
    @Override public String event() { return "graphics-status"; }

    public static GraphicsStatusEvent fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "GraphicsStatusEvent");
        Builder builder = builder();
        ProtocolSupport.literal(Wire.required(object, "event"), "graphics-status", "GraphicsStatusEvent.event");
        Object rawAttempts = Wire.optional(object, "attempts");
        if (!Wire.isMissing(rawAttempts)) {
            builder.attempts(Wire.uint16(rawAttempts, "GraphicsStatusEvent.attempts"));
        }
        Object rawCellHeight = Wire.optional(object, "cell_height");
        if (!Wire.isMissing(rawCellHeight)) {
            builder.cellHeight(Wire.uint16(rawCellHeight, "GraphicsStatusEvent.cell_height"));
        }
        Object rawCellWidth = Wire.optional(object, "cell_width");
        if (!Wire.isMissing(rawCellWidth)) {
            builder.cellWidth(Wire.uint16(rawCellWidth, "GraphicsStatusEvent.cell_width"));
        }
        Object rawError = Wire.optional(object, "error");
        if (!Wire.isMissing(rawError)) {
            builder.error(Wire.string(rawError, "GraphicsStatusEvent.error"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(GraphicsStatusEventKind.fromWire(rawKind));
        Object rawRemaining = Wire.optional(object, "remaining");
        if (!Wire.isMissing(rawRemaining)) {
            builder.remaining(Wire.uint64(rawRemaining, "GraphicsStatusEvent.remaining"));
        }
        Object rawRetryExhausted = Wire.optional(object, "retry_exhausted");
        if (!Wire.isMissing(rawRetryExhausted)) {
            builder.retryExhausted(Wire.bool(rawRetryExhausted, "GraphicsStatusEvent.retry_exhausted"));
        }
        Object rawSummary = Wire.optional(object, "summary");
        if (!Wire.isMissing(rawSummary)) {
            builder.summary(Wire.string(rawSummary, "GraphicsStatusEvent.summary"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        object.put("event", "graphics-status");
        Wire.put(object, "attempts", attempts);
        Wire.put(object, "cell_height", cellHeight);
        Wire.put(object, "cell_width", cellWidth);
        Wire.put(object, "error", error);
        Wire.put(object, "kind", kind);
        Wire.put(object, "remaining", remaining);
        Wire.put(object, "retry_exhausted", retryExhausted);
        Wire.put(object, "summary", summary);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof GraphicsStatusEvent that)) return false;
        return Objects.equals(attempts, that.attempts) && Objects.equals(cellHeight, that.cellHeight) && Objects.equals(cellWidth, that.cellWidth) && Objects.equals(error, that.error) && Objects.equals(kind, that.kind) && Objects.equals(remaining, that.remaining) && Objects.equals(retryExhausted, that.retryExhausted) && Objects.equals(summary, that.summary);
    }

    @Override
    public int hashCode() { return Objects.hash(attempts, cellHeight, cellWidth, error, kind, remaining, retryExhausted, summary); }

    @Override
    public String toString() { return "GraphicsStatusEvent" + toWire(); }

    public static final class Builder {
        private Field<Integer> attempts = Field.omitted();
        private Field<Integer> cellHeight = Field.omitted();
        private Field<Integer> cellWidth = Field.omitted();
        private Field<String> error = Field.omitted();
        private GraphicsStatusEventKind kind;
        private boolean kindSet;
        private Field<UInt64> remaining = Field.omitted();
        private Field<Boolean> retryExhausted = Field.omitted();
        private Field<String> summary = Field.omitted();

        public Builder attempts(Integer value) {
            this.attempts = Field.of(value);
            return this;
        }
        public Builder cellHeight(Integer value) {
            this.cellHeight = Field.of(value);
            return this;
        }
        public Builder cellWidth(Integer value) {
            this.cellWidth = Field.of(value);
            return this;
        }
        public Builder error(String value) {
            this.error = Field.of(value);
            return this;
        }
        public Builder kind(GraphicsStatusEventKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder remaining(UInt64 value) {
            this.remaining = Field.of(value);
            return this;
        }
        public Builder retryExhausted(Boolean value) {
            this.retryExhausted = Field.of(value);
            return this;
        }
        public Builder summary(String value) {
            this.summary = Field.of(value);
            return this;
        }
        public GraphicsStatusEvent build() { return new GraphicsStatusEvent(this); }
    }
}
