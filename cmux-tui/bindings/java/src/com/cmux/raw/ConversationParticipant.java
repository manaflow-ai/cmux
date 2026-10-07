// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationParticipant implements WireValue {
    private final Field<String> acpSession;
    /** Known values: mux, agent. Other values are future classes. */
    private final Field<String> agentClass;
    private final String displayName;
    private final String id;
    /** Known values: human, agent. Other values are future kinds. */
    private final String kind;

    private ConversationParticipant(Builder builder) {
        this.acpSession = builder.acpSession;
        this.agentClass = builder.agentClass;
        if (!builder.displayNameSet) throw new IllegalArgumentException("display_name is required");
        this.displayName = Wire.nonNull(builder.displayName, "display_name");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> acpSession() { return acpSession; }
    public Field<String> agentClass() { return agentClass; }
    public String displayName() { return displayName; }
    public String id() { return id; }
    public String kind() { return kind; }

    public static ConversationParticipant fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationParticipant");
        Builder builder = builder();
        Object rawAcpSession = Wire.optional(object, "acp_session");
        if (!Wire.isMissing(rawAcpSession)) {
            builder.acpSession(Wire.string(rawAcpSession, "ConversationParticipant.acp_session"));
        }
        Object rawAgentClass = Wire.optional(object, "agent_class");
        if (!Wire.isMissing(rawAgentClass)) {
            builder.agentClass(Wire.string(rawAgentClass, "ConversationParticipant.agent_class"));
        }
        Object rawDisplayName = Wire.required(object, "display_name");
        builder.displayName(Wire.string(rawDisplayName, "ConversationParticipant.display_name"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "ConversationParticipant.id"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "ConversationParticipant.kind"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "acp_session", acpSession);
        Wire.put(object, "agent_class", agentClass);
        Wire.put(object, "display_name", displayName);
        Wire.put(object, "id", id);
        Wire.put(object, "kind", kind);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationParticipant that)) return false;
        return Objects.equals(acpSession, that.acpSession) && Objects.equals(agentClass, that.agentClass) && Objects.equals(displayName, that.displayName) && Objects.equals(id, that.id) && Objects.equals(kind, that.kind);
    }

    @Override
    public int hashCode() { return Objects.hash(acpSession, agentClass, displayName, id, kind); }

    @Override
    public String toString() { return "ConversationParticipant" + toWire(); }

    public static final class Builder {
        private Field<String> acpSession = Field.omitted();
        private Field<String> agentClass = Field.omitted();
        private String displayName;
        private boolean displayNameSet;
        private String id;
        private boolean idSet;
        private String kind;
        private boolean kindSet;

        public Builder acpSession(String value) {
            this.acpSession = Field.of(value);
            return this;
        }
        public Builder agentClass(String value) {
            this.agentClass = Field.of(value);
            return this;
        }
        public Builder displayName(String value) {
            this.displayName = value;
            this.displayNameSet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public ConversationParticipant build() { return new ConversationParticipant(this); }
    }
}
