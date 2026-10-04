// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationPartWork implements WireValue, ConversationPart {
    private final Field<String> host;
    private final Field<String> preview;
    private final String session;
    private final ConversationWorkStatus status;

    private ConversationPartWork(Builder builder) {
        this.host = builder.host;
        this.preview = builder.preview;
        if (!builder.sessionSet) throw new IllegalArgumentException("session is required");
        this.session = Wire.nonNull(builder.session, "session");
        if (!builder.statusSet) throw new IllegalArgumentException("status is required");
        this.status = Wire.nonNull(builder.status, "status");
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> host() { return host; }
    public Field<String> preview() { return preview; }
    public String session() { return session; }
    public ConversationWorkStatus status() { return status; }
    public String type() { return "work"; }

    public static ConversationPartWork fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationPartWork");
        Builder builder = builder();
        Object rawHost = Wire.optional(object, "host");
        if (!Wire.isMissing(rawHost)) {
            builder.host(Wire.string(rawHost, "ConversationPartWork.host"));
        }
        Object rawPreview = Wire.optional(object, "preview");
        if (!Wire.isMissing(rawPreview)) {
            builder.preview(Wire.string(rawPreview, "ConversationPartWork.preview"));
        }
        Object rawSession = Wire.required(object, "session");
        builder.session(Wire.string(rawSession, "ConversationPartWork.session"));
        Object rawStatus = Wire.required(object, "status");
        builder.status(ConversationWorkStatus.fromWire(rawStatus));
        Object rawType = Wire.required(object, "type");
        ProtocolSupport.literal(rawType, "work", "ConversationPartWork.type");
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "host", host);
        Wire.put(object, "preview", preview);
        Wire.put(object, "session", session);
        Wire.put(object, "status", status);
        Wire.put(object, "type", "work");
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationPartWork that)) return false;
        return Objects.equals(host, that.host) && Objects.equals(preview, that.preview) && Objects.equals(session, that.session) && Objects.equals(status, that.status);
    }

    @Override
    public int hashCode() { return Objects.hash(host, preview, session, status); }

    @Override
    public String toString() { return "ConversationPartWork" + toWire(); }

    public static final class Builder {
        private Field<String> host = Field.omitted();
        private Field<String> preview = Field.omitted();
        private String session;
        private boolean sessionSet;
        private ConversationWorkStatus status;
        private boolean statusSet;

        public Builder host(String value) {
            this.host = Field.of(value);
            return this;
        }
        public Builder preview(String value) {
            this.preview = Field.of(value);
            return this;
        }
        public Builder session(String value) {
            this.session = value;
            this.sessionSet = true;
            return this;
        }
        public Builder status(ConversationWorkStatus value) {
            this.status = value;
            this.statusSet = true;
            return this;
        }
        public ConversationPartWork build() { return new ConversationPartWork(this); }
    }
}
