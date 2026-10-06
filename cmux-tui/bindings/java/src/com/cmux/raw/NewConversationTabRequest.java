// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable new-conversation-tab request. Protocol v12; authority: control. */
public final class NewConversationTabRequest implements WireValue {
    private final Field<AgentSessionSource> agentSession;
    private final Field<Integer> cols;
    private final Field<String> conversation;
    private final Field<String> mutationId;
    private final Field<String> origin;
    private final Field<String> owner;
    private final Field<UInt64> pane;
    private final Field<Integer> rows;
    /** Client transaction id (1 to 128 printable ASCII), echoed on the created tab's tab-added delta and in the result. */
    private final Field<String> transaction;
    private final Field<UInt64> workspace;

    private NewConversationTabRequest(Builder builder) {
        this.agentSession = builder.agentSession;
        this.cols = builder.cols;
        this.conversation = builder.conversation;
        this.mutationId = builder.mutationId;
        this.origin = builder.origin;
        this.owner = builder.owner;
        this.pane = builder.pane;
        this.rows = builder.rows;
        this.transaction = builder.transaction;
        this.workspace = builder.workspace;
    }

    public static Builder builder() { return new Builder(); }

    public Field<AgentSessionSource> agentSession() { return agentSession; }
    public Field<Integer> cols() { return cols; }
    public Field<String> conversation() { return conversation; }
    public Field<String> mutationId() { return mutationId; }
    public Field<String> origin() { return origin; }
    public Field<String> owner() { return owner; }
    public Field<UInt64> pane() { return pane; }
    public Field<Integer> rows() { return rows; }
    public Field<String> transaction() { return transaction; }
    public Field<UInt64> workspace() { return workspace; }

    public static NewConversationTabRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NewConversationTabRequest");
        Builder builder = builder();
        Object rawAgentSession = Wire.optional(object, "agent_session");
        if (!Wire.isMissing(rawAgentSession)) {
            builder.agentSession(rawAgentSession == null ? null : AgentSessionSource.fromWire(rawAgentSession));
        }
        Object rawCols = Wire.optional(object, "cols");
        if (!Wire.isMissing(rawCols)) {
            builder.cols(rawCols == null ? null : Wire.uint16(rawCols, "NewConversationTabRequest.cols"));
        }
        Object rawConversation = Wire.optional(object, "conversation");
        if (!Wire.isMissing(rawConversation)) {
            builder.conversation(rawConversation == null ? null : Wire.string(rawConversation, "NewConversationTabRequest.conversation"));
        }
        Object rawMutationId = Wire.optional(object, "mutation_id");
        if (!Wire.isMissing(rawMutationId)) {
            builder.mutationId(rawMutationId == null ? null : Wire.string(rawMutationId, "NewConversationTabRequest.mutation_id"));
        }
        Object rawOrigin = Wire.optional(object, "origin");
        if (!Wire.isMissing(rawOrigin)) {
            builder.origin(rawOrigin == null ? null : Wire.string(rawOrigin, "NewConversationTabRequest.origin"));
        }
        Object rawOwner = Wire.optional(object, "owner");
        if (!Wire.isMissing(rawOwner)) {
            builder.owner(rawOwner == null ? null : Wire.string(rawOwner, "NewConversationTabRequest.owner"));
        }
        Object rawPane = Wire.optional(object, "pane");
        if (!Wire.isMissing(rawPane)) {
            builder.pane(rawPane == null ? null : Wire.uint64(rawPane, "NewConversationTabRequest.pane"));
        }
        Object rawRows = Wire.optional(object, "rows");
        if (!Wire.isMissing(rawRows)) {
            builder.rows(rawRows == null ? null : Wire.uint16(rawRows, "NewConversationTabRequest.rows"));
        }
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "NewConversationTabRequest.transaction"));
        }
        Object rawWorkspace = Wire.optional(object, "workspace");
        if (!Wire.isMissing(rawWorkspace)) {
            builder.workspace(rawWorkspace == null ? null : Wire.uint64(rawWorkspace, "NewConversationTabRequest.workspace"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "agent_session", agentSession);
        Wire.put(object, "cols", cols);
        Wire.put(object, "conversation", conversation);
        Wire.put(object, "mutation_id", mutationId);
        Wire.put(object, "origin", origin);
        Wire.put(object, "owner", owner);
        Wire.put(object, "pane", pane);
        Wire.put(object, "rows", rows);
        Wire.put(object, "transaction", transaction);
        Wire.put(object, "workspace", workspace);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NewConversationTabRequest that)) return false;
        return Objects.equals(agentSession, that.agentSession) && Objects.equals(cols, that.cols) && Objects.equals(conversation, that.conversation) && Objects.equals(mutationId, that.mutationId) && Objects.equals(origin, that.origin) && Objects.equals(owner, that.owner) && Objects.equals(pane, that.pane) && Objects.equals(rows, that.rows) && Objects.equals(transaction, that.transaction) && Objects.equals(workspace, that.workspace);
    }

    @Override
    public int hashCode() { return Objects.hash(agentSession, cols, conversation, mutationId, origin, owner, pane, rows, transaction, workspace); }

    @Override
    public String toString() { return "NewConversationTabRequest" + toWire(); }

    public static final class Builder {
        private Field<AgentSessionSource> agentSession = Field.omitted();
        private Field<Integer> cols = Field.omitted();
        private Field<String> conversation = Field.omitted();
        private Field<String> mutationId = Field.omitted();
        private Field<String> origin = Field.omitted();
        private Field<String> owner = Field.omitted();
        private Field<UInt64> pane = Field.omitted();
        private Field<Integer> rows = Field.omitted();
        private Field<String> transaction = Field.omitted();
        private Field<UInt64> workspace = Field.omitted();

        public Builder agentSession(AgentSessionSource value) {
            this.agentSession = Field.ofNullable(value);
            return this;
        }
        public Builder cols(Integer value) {
            this.cols = Field.ofNullable(value);
            return this;
        }
        public Builder conversation(String value) {
            this.conversation = Field.ofNullable(value);
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
        public Builder owner(String value) {
            this.owner = Field.ofNullable(value);
            return this;
        }
        public Builder pane(UInt64 value) {
            this.pane = Field.ofNullable(value);
            return this;
        }
        public Builder rows(Integer value) {
            this.rows = Field.ofNullable(value);
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public Builder workspace(UInt64 value) {
            this.workspace = Field.ofNullable(value);
            return this;
        }
        public NewConversationTabRequest build() { return new NewConversationTabRequest(this); }
    }
}
