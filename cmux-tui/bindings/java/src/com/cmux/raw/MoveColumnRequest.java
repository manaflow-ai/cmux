// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-column request. Protocol v12; authority: control. */
public final class MoveColumnRequest implements WireValue {
    private final ColumnMoveDirection direction;
    private final UInt64 pane;

    private MoveColumnRequest(Builder builder) {
        if (!builder.directionSet) throw new IllegalArgumentException("direction is required");
        this.direction = Wire.nonNull(builder.direction, "direction");
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
    }

    public static Builder builder() { return new Builder(); }

    public ColumnMoveDirection direction() { return direction; }
    public UInt64 pane() { return pane; }

    public static MoveColumnRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveColumnRequest");
        Builder builder = builder();
        Object rawDirection = Wire.required(object, "direction");
        builder.direction(ColumnMoveDirection.fromWire(rawDirection));
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "MoveColumnRequest.pane"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "direction", direction);
        Wire.put(object, "pane", pane);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveColumnRequest that)) return false;
        return Objects.equals(direction, that.direction) && Objects.equals(pane, that.pane);
    }

    @Override
    public int hashCode() { return Objects.hash(direction, pane); }

    @Override
    public String toString() { return "MoveColumnRequest" + toWire(); }

    public static final class Builder {
        private ColumnMoveDirection direction;
        private boolean directionSet;
        private UInt64 pane;
        private boolean paneSet;

        public Builder direction(ColumnMoveDirection value) {
            this.direction = value;
            this.directionSet = true;
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public MoveColumnRequest build() { return new MoveColumnRequest(this); }
    }
}
