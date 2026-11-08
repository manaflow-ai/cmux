// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-terminal request. Protocol v9; authority: control. */
public final class CloseTerminalRequest implements WireValue {
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedRevision;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final String terminalId;
    private final Field<String> terminalIncarnation;

    private CloseTerminalRequest(Builder builder) {
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedRevision = builder.expectedRevision;
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        if (!builder.terminalIdSet) throw new IllegalArgumentException("terminal_id is required");
        this.terminalId = Wire.nonNull(builder.terminalId, "terminal_id");
        this.terminalIncarnation = builder.terminalIncarnation;
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public String terminalId() { return terminalId; }
    public Field<String> terminalIncarnation() { return terminalIncarnation; }

    public static CloseTerminalRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseTerminalRequest");
        Builder builder = builder();
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "CloseTerminalRequest.expected_generation"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "CloseTerminalRequest.expected_revision"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "CloseTerminalRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "CloseTerminalRequest.origin"));
        }
        Object rawTerminalId = Wire.required(object, "terminal_id");
        builder.terminalId(Wire.string(rawTerminalId, "CloseTerminalRequest.terminal_id"));
        Object rawTerminalIncarnation = Wire.optional(object, "terminal_incarnation");
        if (!Wire.isMissing(rawTerminalIncarnation)) {
            builder.terminalIncarnation(rawTerminalIncarnation == null ? null : Wire.string(rawTerminalIncarnation, "CloseTerminalRequest.terminal_incarnation"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "terminal_id", terminalId);
        Wire.put(object, "terminal_incarnation", terminalIncarnation);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseTerminalRequest that)) return false;
        return Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(terminalId, that.terminalId) && Objects.equals(terminalIncarnation, that.terminalIncarnation);
    }

    @Override
    public int hashCode() { return Objects.hash(expectedGeneration, expectedRevision, mutationId, origin, terminalId, terminalIncarnation); }

    @Override
    public String toString() { return "CloseTerminalRequest" + toWire(); }

    public static final class Builder {
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private String terminalId;
        private boolean terminalIdSet;
        private Field<String> terminalIncarnation = Field.omitted();

        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
            return this;
        }
        public Builder mutationId(String value) {
            this.mutationId = Field.ofNullable(value);
            return this;
        }
        public Builder origin(String value) {
            this.origin = Field.ofNullable(value);
            return this;
        }
        public Builder terminalId(String value) {
            this.terminalId = value;
            this.terminalIdSet = true;
            return this;
        }
        public Builder terminalIncarnation(String value) {
            this.terminalIncarnation = Field.ofNullable(value);
            return this;
        }
        public CloseTerminalRequest build() { return new CloseTerminalRequest(this); }
    }
}
