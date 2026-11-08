// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable undo-layout request. Protocol v9; authority: control. */
public final class UndoLayoutRequest implements WireValue {
    private final Field<Boolean> confirmClose;
    private final UInt64 pane;
    private final Field<UInt64> revision;

    private UndoLayoutRequest(Builder builder) {
        this.confirmClose = builder.confirmClose;
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        this.revision = builder.revision;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> confirmClose() { return confirmClose; }
    public UInt64 pane() { return pane; }
    public Field<UInt64> revision() { return revision; }

    public static UndoLayoutRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "UndoLayoutRequest");
        Builder builder = builder();
        Object rawConfirmClose = Wire.optional(object, "confirm_close");
        if (!Wire.isMissing(rawConfirmClose)) {
            builder.confirmClose(Wire.bool(rawConfirmClose, "UndoLayoutRequest.confirm_close"));
        }
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "UndoLayoutRequest.pane"));
        Object rawRevision = Wire.optional(object, "revision");
        if (!Wire.isMissing(rawRevision)) {
            builder.revision(rawRevision == null ? null : Wire.uint64(rawRevision, "UndoLayoutRequest.revision"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "confirm_close", confirmClose);
        Wire.put(object, "pane", pane);
        Wire.put(object, "revision", revision);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof UndoLayoutRequest that)) return false;
        return Objects.equals(confirmClose, that.confirmClose) && Objects.equals(pane, that.pane) && Objects.equals(revision, that.revision);
    }

    @Override
    public int hashCode() { return Objects.hash(confirmClose, pane, revision); }

    @Override
    public String toString() { return "UndoLayoutRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> confirmClose = Field.omitted();
        private UInt64 pane;
        private boolean paneSet;
        private Field<UInt64> revision = Field.omitted();

        public Builder confirmClose(Boolean value) {
            this.confirmClose = Field.of(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder revision(UInt64 value) {
            this.revision = Field.ofNullable(value);
            return this;
        }
        public UndoLayoutRequest build() { return new UndoLayoutRequest(this); }
    }
}
