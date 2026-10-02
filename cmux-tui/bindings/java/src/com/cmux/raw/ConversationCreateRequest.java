// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable conversation-create request. Protocol v12; authority: local-admin. */
public final class ConversationCreateRequest implements WireValue {
    private final String actor;
    private final String idempotencyKey;
    private final Object participants;
    private final String title;

    private ConversationCreateRequest(Builder builder) {
        if (!builder.actorSet) throw new IllegalArgumentException("actor is required");
        this.actor = Wire.nonNull(builder.actor, "actor");
        if (!builder.idempotencyKeySet) throw new IllegalArgumentException("idempotency_key is required");
        this.idempotencyKey = Wire.nonNull(builder.idempotencyKey, "idempotency_key");
        if (!builder.participantsSet) throw new IllegalArgumentException("participants is required");
        this.participants = builder.participants == null ? null : Wire.immutableJson(builder.participants);
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public String actor() { return actor; }
    public String idempotencyKey() { return idempotencyKey; }
    public Object participants() { return participants; }
    public String title() { return title; }

    public static ConversationCreateRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationCreateRequest");
        Builder builder = builder();
        Object rawActor = Wire.required(object, "actor");
        builder.actor(Wire.string(rawActor, "ConversationCreateRequest.actor"));
        Object rawIdempotencyKey = Wire.required(object, "idempotency_key");
        builder.idempotencyKey(Wire.string(rawIdempotencyKey, "ConversationCreateRequest.idempotency_key"));
        Object rawParticipants = Wire.required(object, "participants");
        builder.participants(rawParticipants == null ? null : Wire.immutableJson(rawParticipants));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "ConversationCreateRequest.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "actor", actor);
        Wire.put(object, "idempotency_key", idempotencyKey);
        Wire.put(object, "participants", participants);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationCreateRequest that)) return false;
        return Objects.equals(actor, that.actor) && Objects.equals(idempotencyKey, that.idempotencyKey) && Objects.equals(participants, that.participants) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(actor, idempotencyKey, participants, title); }

    @Override
    public String toString() { return "ConversationCreateRequest" + toWire(); }

    public static final class Builder {
        private String actor;
        private boolean actorSet;
        private String idempotencyKey;
        private boolean idempotencyKeySet;
        private Object participants;
        private boolean participantsSet;
        private String title;
        private boolean titleSet;

        public Builder actor(String value) {
            this.actor = value;
            this.actorSet = true;
            return this;
        }
        public Builder idempotencyKey(String value) {
            this.idempotencyKey = value;
            this.idempotencyKeySet = true;
            return this;
        }
        public Builder participants(Object value) {
            this.participants = value;
            this.participantsSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public ConversationCreateRequest build() { return new ConversationCreateRequest(this); }
    }
}
