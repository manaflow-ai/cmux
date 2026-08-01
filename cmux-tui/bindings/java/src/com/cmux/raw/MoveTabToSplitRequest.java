// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable move-tab-to-split request. Protocol v10; authority: control. */
public final class MoveTabToSplitRequest implements WireValue {
    private final Field<Boolean> activate;
    private final SplitDirection dir;
    private final Field<Boolean> insertFirst;
    private final UInt64 pane;
    private final UInt64 surface;

    private MoveTabToSplitRequest(Builder builder) {
        this.activate = builder.activate;
        if (!builder.dirSet) throw new IllegalArgumentException("dir is required");
        this.dir = Wire.nonNull(builder.dir, "dir");
        this.insertFirst = builder.insertFirst;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> activate() { return activate; }
    public SplitDirection dir() { return dir; }
    public Field<Boolean> insertFirst() { return insertFirst; }
    public UInt64 pane() { return pane; }
    public UInt64 surface() { return surface; }

    public static MoveTabToSplitRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "MoveTabToSplitRequest");
        Builder builder = builder();
        Object rawActivate = Wire.optional(object, "activate");
        if (!Wire.isMissing(rawActivate)) {
            builder.activate(rawActivate == null ? null : Wire.bool(rawActivate, "MoveTabToSplitRequest.activate"));
        }
        Object rawDir = Wire.required(object, "dir");
        builder.dir(SplitDirection.fromWire(rawDir));
        Object rawInsertFirst = Wire.optional(object, "insert_first");
        if (!Wire.isMissing(rawInsertFirst)) {
            builder.insertFirst(Wire.bool(rawInsertFirst, "MoveTabToSplitRequest.insert_first"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "MoveTabToSplitRequest.pane"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "MoveTabToSplitRequest.surface"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "activate", activate);
        Wire.put(object, "dir", dir);
        Wire.put(object, "insert_first", insertFirst);
        Wire.put(object, "pane", pane);
        Wire.put(object, "surface", surface);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof MoveTabToSplitRequest that)) return false;
        return Objects.equals(activate, that.activate) && Objects.equals(dir, that.dir) && Objects.equals(insertFirst, that.insertFirst) && Objects.equals(pane, that.pane) && Objects.equals(surface, that.surface);
    }

    @Override
    public int hashCode() { return Objects.hash(activate, dir, insertFirst, pane, surface); }

    @Override
    public String toString() { return "MoveTabToSplitRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> activate = Field.omitted();
        private SplitDirection dir;
        private boolean dirSet;
        private Field<Boolean> insertFirst = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 surface;
        private boolean surfaceSet;

        public Builder activate(Boolean value) {
            this.activate = Field.ofNullable(value);
            return this;
        }
        public Builder dir(SplitDirection value) {
            this.dir = value;
            this.dirSet = true;
            return this;
        }
        public Builder insertFirst(Boolean value) {
            this.insertFirst = Field.of(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public MoveTabToSplitRequest build() { return new MoveTabToSplitRequest(this); }
    }
}
