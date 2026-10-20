// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class SizeState implements WireValue {
    private final int cols;
    private final UInt64 generation;
    private final List<String> owners;
    private final List<SizeParticipant> participants;
    private final SizePolicy policy;
    private final SizeReason reason;
    private final int rows;

    private SizeState(Builder builder) {
        if (!builder.colsSet) throw new IllegalArgumentException("cols is required");
        this.cols = builder.cols;
        if (!builder.generationSet) throw new IllegalArgumentException("generation is required");
        this.generation = Wire.nonNull(builder.generation, "generation");
        if (!builder.ownersSet) throw new IllegalArgumentException("owners is required");
        this.owners = List.copyOf(Wire.nonNull(builder.owners, "owners"));
        if (!builder.participantsSet) throw new IllegalArgumentException("participants is required");
        this.participants = List.copyOf(Wire.nonNull(builder.participants, "participants"));
        if (!builder.policySet) throw new IllegalArgumentException("policy is required");
        this.policy = Wire.nonNull(builder.policy, "policy");
        if (!builder.reasonSet) throw new IllegalArgumentException("reason is required");
        this.reason = Wire.nonNull(builder.reason, "reason");
        if (!builder.rowsSet) throw new IllegalArgumentException("rows is required");
        this.rows = builder.rows;
    }

    public static Builder builder() { return new Builder(); }

    public int cols() { return cols; }
    public UInt64 generation() { return generation; }
    public List<String> owners() { return owners; }
    public List<SizeParticipant> participants() { return participants; }
    public SizePolicy policy() { return policy; }
    public SizeReason reason() { return reason; }
    public int rows() { return rows; }

    public static SizeState fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SizeState");
        Builder builder = builder();
        Object rawCols = Wire.required(object, "cols");
        builder.cols(Wire.uint16(rawCols, "SizeState.cols"));
        Object rawGeneration = Wire.required(object, "generation");
        builder.generation(Wire.uint64(rawGeneration, "SizeState.generation"));
        Object rawOwners = Wire.required(object, "owners");
        builder.owners(Wire.array(rawOwners, "SizeState.owners", item -> Wire.string(item, "SizeState.owners item")));
        Object rawParticipants = Wire.required(object, "participants");
        builder.participants(Wire.array(rawParticipants, "SizeState.participants", item -> SizeParticipant.fromWire(item)));
        Object rawPolicy = Wire.required(object, "policy");
        builder.policy(SizePolicy.fromWire(rawPolicy));
        Object rawReason = Wire.required(object, "reason");
        builder.reason(SizeReason.fromWire(rawReason));
        Object rawRows = Wire.required(object, "rows");
        builder.rows(Wire.uint16(rawRows, "SizeState.rows"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cols", cols);
        Wire.put(object, "generation", generation);
        Wire.put(object, "owners", owners);
        Wire.put(object, "participants", participants);
        Wire.put(object, "policy", policy);
        Wire.put(object, "reason", reason);
        Wire.put(object, "rows", rows);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SizeState that)) return false;
        return Objects.equals(cols, that.cols) && Objects.equals(generation, that.generation) && Objects.equals(owners, that.owners) && Objects.equals(participants, that.participants) && Objects.equals(policy, that.policy) && Objects.equals(reason, that.reason) && Objects.equals(rows, that.rows);
    }

    @Override
    public int hashCode() { return Objects.hash(cols, generation, owners, participants, policy, reason, rows); }

    @Override
    public String toString() { return "SizeState" + toWire(); }

    public static final class Builder {
        private Integer cols;
        private boolean colsSet;
        private UInt64 generation;
        private boolean generationSet;
        private List<String> owners;
        private boolean ownersSet;
        private List<SizeParticipant> participants;
        private boolean participantsSet;
        private SizePolicy policy;
        private boolean policySet;
        private SizeReason reason;
        private boolean reasonSet;
        private Integer rows;
        private boolean rowsSet;

        public Builder cols(int value) {
            this.cols = value;
            this.colsSet = true;
            return this;
        }
        public Builder generation(UInt64 value) {
            this.generation = value;
            this.generationSet = true;
            return this;
        }
        public Builder owners(List<String> value) {
            this.owners = value;
            this.ownersSet = true;
            return this;
        }
        public Builder participants(List<SizeParticipant> value) {
            this.participants = value;
            this.participantsSet = true;
            return this;
        }
        public Builder policy(SizePolicy value) {
            this.policy = value;
            this.policySet = true;
            return this;
        }
        public Builder reason(SizeReason value) {
            this.reason = value;
            this.reasonSet = true;
            return this;
        }
        public Builder rows(int value) {
            this.rows = value;
            this.rowsSet = true;
            return this;
        }
        public SizeState build() { return new SizeState(this); }
    }
}
