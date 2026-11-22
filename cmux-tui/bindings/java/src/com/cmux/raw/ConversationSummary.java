// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationSummary implements WireValue {
    private final String createdAt;
    private final String id;
    private final Field<ConversationMessage> lastMessage;
    private final UInt64 lastSeq;
    private final String owner;
    private final List<ConversationParticipant> participants;
    private final Map<String, UInt64> readCursors;
    private final UInt64 rev;
    private final String title;
    private final String updatedAt;

    private ConversationSummary(Builder builder) {
        if (!builder.createdAtSet) throw new IllegalArgumentException("created_at is required");
        this.createdAt = Wire.nonNull(builder.createdAt, "created_at");
        if (!builder.idSet) throw new IllegalArgumentException("id is required");
        this.id = Wire.nonNull(builder.id, "id");
        this.lastMessage = builder.lastMessage;
        if (!builder.lastSeqSet) throw new IllegalArgumentException("last_seq is required");
        this.lastSeq = Wire.nonNull(builder.lastSeq, "last_seq");
        if (!builder.ownerSet) throw new IllegalArgumentException("owner is required");
        this.owner = Wire.nonNull(builder.owner, "owner");
        if (!builder.participantsSet) throw new IllegalArgumentException("participants is required");
        this.participants = List.copyOf(Wire.nonNull(builder.participants, "participants"));
        if (!builder.readCursorsSet) throw new IllegalArgumentException("read_cursors is required");
        this.readCursors = Collections.unmodifiableMap(new LinkedHashMap<>(Wire.nonNull(builder.readCursors, "read_cursors")));
        if (!builder.revSet) throw new IllegalArgumentException("rev is required");
        this.rev = Wire.nonNull(builder.rev, "rev");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
        if (!builder.updatedAtSet) throw new IllegalArgumentException("updated_at is required");
        this.updatedAt = Wire.nonNull(builder.updatedAt, "updated_at");
    }

    public static Builder builder() { return new Builder(); }

    public String createdAt() { return createdAt; }
    public String id() { return id; }
    public Field<ConversationMessage> lastMessage() { return lastMessage; }
    public UInt64 lastSeq() { return lastSeq; }
    public String owner() { return owner; }
    public List<ConversationParticipant> participants() { return participants; }
    public Map<String, UInt64> readCursors() { return readCursors; }
    public UInt64 rev() { return rev; }
    public String title() { return title; }
    public String updatedAt() { return updatedAt; }

    public static ConversationSummary fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationSummary");
        Builder builder = builder();
        Object rawCreatedAt = Wire.required(object, "created_at");
        builder.createdAt(Wire.string(rawCreatedAt, "ConversationSummary.created_at"));
        Object rawId = Wire.required(object, "id");
        builder.id(Wire.string(rawId, "ConversationSummary.id"));
        Object rawLastMessage = Wire.optional(object, "last_message");
        if (!Wire.isMissing(rawLastMessage)) {
            builder.lastMessage(ConversationMessage.fromWire(rawLastMessage));
        }
        Object rawLastSeq = Wire.required(object, "last_seq");
        builder.lastSeq(Wire.uint64(rawLastSeq, "ConversationSummary.last_seq"));
        Object rawOwner = Wire.required(object, "owner");
        builder.owner(Wire.string(rawOwner, "ConversationSummary.owner"));
        Object rawParticipants = Wire.required(object, "participants");
        builder.participants(Wire.array(rawParticipants, "ConversationSummary.participants", item -> ConversationParticipant.fromWire(item)));
        Object rawReadCursors = Wire.required(object, "read_cursors");
        builder.readCursors(Wire.map(rawReadCursors, "ConversationSummary.read_cursors", item -> Wire.uint64(item, "ConversationSummary.read_cursors value")));
        Object rawRev = Wire.required(object, "rev");
        builder.rev(Wire.uint64(rawRev, "ConversationSummary.rev"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "ConversationSummary.title"));
        Object rawUpdatedAt = Wire.required(object, "updated_at");
        builder.updatedAt(Wire.string(rawUpdatedAt, "ConversationSummary.updated_at"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "created_at", createdAt);
        Wire.put(object, "id", id);
        Wire.put(object, "last_message", lastMessage);
        Wire.put(object, "last_seq", lastSeq);
        Wire.put(object, "owner", owner);
        Wire.put(object, "participants", participants);
        Wire.put(object, "read_cursors", readCursors);
        Wire.put(object, "rev", rev);
        Wire.put(object, "title", title);
        Wire.put(object, "updated_at", updatedAt);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationSummary that)) return false;
        return Objects.equals(createdAt, that.createdAt) && Objects.equals(id, that.id) && Objects.equals(lastMessage, that.lastMessage) && Objects.equals(lastSeq, that.lastSeq) && Objects.equals(owner, that.owner) && Objects.equals(participants, that.participants) && Objects.equals(readCursors, that.readCursors) && Objects.equals(rev, that.rev) && Objects.equals(title, that.title) && Objects.equals(updatedAt, that.updatedAt);
    }

    @Override
    public int hashCode() { return Objects.hash(createdAt, id, lastMessage, lastSeq, owner, participants, readCursors, rev, title, updatedAt); }

    @Override
    public String toString() { return "ConversationSummary" + toWire(); }

    public static final class Builder {
        private String createdAt;
        private boolean createdAtSet;
        private String id;
        private boolean idSet;
        private Field<ConversationMessage> lastMessage = Field.omitted();
        private UInt64 lastSeq;
        private boolean lastSeqSet;
        private String owner;
        private boolean ownerSet;
        private List<ConversationParticipant> participants;
        private boolean participantsSet;
        private Map<String, UInt64> readCursors;
        private boolean readCursorsSet;
        private UInt64 rev;
        private boolean revSet;
        private String title;
        private boolean titleSet;
        private String updatedAt;
        private boolean updatedAtSet;

        public Builder createdAt(String value) {
            this.createdAt = value;
            this.createdAtSet = true;
            return this;
        }
        public Builder id(String value) {
            this.id = value;
            this.idSet = true;
            return this;
        }
        public Builder lastMessage(ConversationMessage value) {
            this.lastMessage = Field.of(value);
            return this;
        }
        public Builder lastSeq(UInt64 value) {
            this.lastSeq = value;
            this.lastSeqSet = true;
            return this;
        }
        public Builder owner(String value) {
            this.owner = value;
            this.ownerSet = true;
            return this;
        }
        public Builder participants(List<ConversationParticipant> value) {
            this.participants = value;
            this.participantsSet = true;
            return this;
        }
        public Builder readCursors(Map<String, UInt64> value) {
            this.readCursors = value;
            this.readCursorsSet = true;
            return this;
        }
        public Builder rev(UInt64 value) {
            this.rev = value;
            this.revSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Builder updatedAt(String value) {
            this.updatedAt = value;
            this.updatedAtSet = true;
            return this;
        }
        public ConversationSummary build() { return new ConversationSummary(this); }
    }
}
