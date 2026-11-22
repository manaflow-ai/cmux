// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class NewRowResult implements WireValue {
    private final UInt64 pane;
    private final UInt64 surface;
    private final Field<String> terminalId;
    private final Field<String> terminalIncarnation;
    private final Field<String> transaction;

    private NewRowResult(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.terminalId = builder.terminalId;
        this.terminalIncarnation = builder.terminalIncarnation;
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public UInt64 pane() { return pane; }
    public UInt64 surface() { return surface; }
    public Field<String> terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }
    public Field<String> transaction() { return transaction; }

    public static NewRowResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewRowResult");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.uint64(rawPane, "NewRowResult.pane"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "NewRowResult.surface"));
        Object rawTerminalId = Wire.optional(object, "terminal_id");
        if (!Wire.isMissing(rawTerminalId)) {
            builder.terminalId(rawTerminalId == null ? null : Wire.string(rawTerminalId, "NewRowResult.terminal_id"));
        }
        Object rawTerminalIncarnation = Wire.optional(object, "terminal_incarnation");
        if (!Wire.isMissing(rawTerminalIncarnation)) {
            builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "NewRowResult.terminal_incarnation"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(Wire.string(rawTransaction, "NewRowResult.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "surface", surface);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewRowResult that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(surface, that.surface) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, surface, terminalId, terminalIncarnation, transaction); }

    @Override
    public String toString() { return "NewRowResult" + toWire(); }

    public static final class Builder {
        private UInt64 pane;
        private boolean paneSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<String> terminalId = Field.omitted();
        private Field<String> terminalIncarnation = Field.omitted();
        private Field<String> transaction = Field.omitted();

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
        public Builder terminalId(String value) {
            this.terminalId = Field.ofNullable(value);
            return this;
        }
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = Field.ofNullable(value);
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.of(value);
            return this;
        }
        public NewRowResult build() { return new NewRowResult(this); }
    }
}
