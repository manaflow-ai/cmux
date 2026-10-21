// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable close-workspace request. Protocol v5; authority: control. */
public final class CloseWorkspaceRequest implements WireValue {
    private final Field<Boolean> endTerminals;
    private final Field<String> expectedGeneration;
    private final Field<UInt64> expectedRevision;
    /** Close only when the workspace has no tab at commit time; otherwise workspace_not_empty and no change. */
    private final Field<Boolean> ifEmpty;
    private final Field<String> key;
    private final Field<String> mutationId;
    private final Field<String> origin;
    /** With end_terminals: the close is not recorded in the closed history (session_end). */
    private final Field<CloseReason> reason;
    /** With end_terminals: the result names closed_ids, the closed.list groups the close stored. Opt-in so older decoders keep the result shape; a daemon that predates it ignores the field. */
    private final Field<Boolean> reportClosedIds;
    private final Field<UInt64> workspace;

    private CloseWorkspaceRequest(Builder builder) {
        this.endTerminals = builder.endTerminals;
        this.expectedGeneration = builder.expectedGeneration;
        this.expectedRevision = builder.expectedRevision;
        this.ifEmpty = builder.ifEmpty;
        this.key = builder.key;
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        this.reason = builder.reason;
        this.reportClosedIds = builder.reportClosedIds;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> endTerminals() { return endTerminals; }
    public Field<String> expectedGeneration() { return expectedGeneration; }
    public Field<UInt64> expectedRevision() { return expectedRevision; }
    public Field<Boolean> ifEmpty() { return ifEmpty; }
    public Field<String> key() { return key; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public Field<CloseReason> reason() { return reason; }
    public Field<Boolean> reportClosedIds() { return reportClosedIds; }
    public Field<UInt64> workspace() { return workspace; }

    public static CloseWorkspaceRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "CloseWorkspaceRequest");
        Builder builder = builder();
        Object rawEndTerminals = Wire.optional(object, "end_terminals");
        if (!Wire.isMissing(rawEndTerminals)) {
            builder.endTerminals(Wire.bool(rawEndTerminals, "CloseWorkspaceRequest.end_terminals"));
        }
        Object rawExpectedGeneration = Wire.optional(object, "expected_generation");
        if (!Wire.isMissing(rawExpectedGeneration)) {
            builder.expectedGeneration(rawExpectedGeneration == null ? null : Wire.string(rawExpectedGeneration, "CloseWorkspaceRequest.expected_generation"));
        }
        Object rawExpectedRevision = Wire.optional(object, "expected_revision", "expected_terminal_revision");
        if (!Wire.isMissing(rawExpectedRevision)) {
            builder.expectedRevision(rawExpectedRevision == null ? null : Wire.uint64(rawExpectedRevision, "CloseWorkspaceRequest.expected_revision"));
        }
        Object rawIfEmpty = Wire.optional(object, "if_empty");
        if (!Wire.isMissing(rawIfEmpty)) {
            builder.ifEmpty(Wire.bool(rawIfEmpty, "CloseWorkspaceRequest.if_empty"));
        }
        Object rawKey = Wire.optional(object, "key");
        if (!Wire.isMissing(rawKey)) {
            builder.key(rawKey == null ? null : Wire.string(rawKey, "CloseWorkspaceRequest.key"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "CloseWorkspaceRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "CloseWorkspaceRequest.origin"));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(rawReason == null ? null : CloseReason.fromWire(rawReason));
        }
        Object rawReportClosedIds = Wire.optional(object, "report_closed_ids");
        if (!Wire.isMissing(rawReportClosedIds)) {
            builder.reportClosedIds(Wire.bool(rawReportClosedIds, "CloseWorkspaceRequest.report_closed_ids"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "CloseWorkspaceRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "end_terminals", endTerminals);
        Wire.put(object, "expected_generation", expectedGeneration);
        Wire.put(object, "expected_revision", expectedRevision);
        Wire.put(object, "if_empty", ifEmpty);
        Wire.put(object, "key", key);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "reason", reason);
        Wire.put(object, "report_closed_ids", reportClosedIds);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof CloseWorkspaceRequest that)) return false;
        return Objects.equals(endTerminals, that.endTerminals) && Objects.equals(expectedGeneration, that.expectedGeneration) && Objects.equals(expectedRevision, that.expectedRevision) && Objects.equals(ifEmpty, that.ifEmpty) && Objects.equals(key, that.key) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(reason, that.reason) && Objects.equals(reportClosedIds, that.reportClosedIds) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(endTerminals, expectedGeneration, expectedRevision, ifEmpty, key, mutationId, origin, reason, reportClosedIds, workspace); }

    @Override
    public String toString() { return "CloseWorkspaceRequest" + toWire(); }

    public static final class Builder {
        private Field<Boolean> endTerminals = Field.omitted();
        private Field<String> expectedGeneration = Field.omitted();
        private Field<UInt64> expectedRevision = Field.omitted();
        private Field<Boolean> ifEmpty = Field.omitted();
        private Field<String> key = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private Field<CloseReason> reason = Field.omitted();
        private Field<Boolean> reportClosedIds = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder endTerminals(Boolean value) {
            this.endTerminals = Field.of(value);
            return this;
        }
        public Builder expectedGeneration(String value) {
            this.expectedGeneration = Field.ofNullable(value);
            return this;
        }
        public Builder expectedRevision(UInt64 value) {
            this.expectedRevision = Field.ofNullable(value);
            return this;
        }
        public Builder ifEmpty(Boolean value) {
            this.ifEmpty = Field.of(value);
            return this;
        }
        public Builder key(String value) {
            this.key = Field.ofNullable(value);
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
        public Builder reason(CloseReason value) {
            this.reason = Field.ofNullable(value);
            return this;
        }
        public Builder reportClosedIds(Boolean value) {
            this.reportClosedIds = Field.of(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public CloseWorkspaceRequest build() { return new CloseWorkspaceRequest(this); }
    }
}
