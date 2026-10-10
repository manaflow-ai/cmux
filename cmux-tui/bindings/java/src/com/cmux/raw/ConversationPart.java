// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationPart implements WireValue {
    /** type work. */
    private final Field<String> host;
    /** type work: the reply preview (a string). type attachment (local-attachments-v1): an image's preview object {hash, mime_type, byte_count}. */
    private final Field<Object> preview;
    /** type text. */
    private final Field<List<ConversationTextRun>> runs;
    /** type work. */
    private final Field<String> session;
    /** type work. Known values: running, done, failed, waiting. */
    private final Field<String> status;
    /** type text. */
    private final Field<String> text;
    /** Known values: text (text, runs), work (session, host, status, preview) and, with local-attachments-v1, attachment (hash, name, mime_type, byte_count, width, height, duration_ms, poster, preview) and link_preview (url, title, site, image; see spec/commands.md). A part of another type keeps its fields in the additional properties. */
    private final String type;
    private final Map<String, Object> additionalProperties;

    private ConversationPart(Builder builder) {
        this.host = builder.host;
        this.preview = builder.preview.map(value -> Wire.immutableJson(value));
        this.runs = builder.runs.map(value -> List.copyOf(value));
        this.session = builder.session;
        this.status = builder.status;
        this.text = builder.text;
        if (!builder.typeSet) throw new IllegalArgumentException("type is required");
        this.type = Wire.nonNull(builder.type, "type");
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<String> host() { return host; }
    public Field<Object> preview() { return preview; }
    public Field<List<ConversationTextRun>> runs() { return runs; }
    public Field<String> session() { return session; }
    public Field<String> status() { return status; }
    public Field<String> text() { return text; }
    public String type() { return type; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static ConversationPart fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationPart");
        Builder builder = builder();
        Object rawHost = Wire.optional(object, "host");
        if (!Wire.isMissing(rawHost)) {
            builder.host(Wire.string(rawHost, "ConversationPart.host"));
        }
        Object rawPreview = Wire.optional(object, "preview");
        if (!Wire.isMissing(rawPreview)) {
            builder.preview(Wire.immutableJson(rawPreview));
        }
        Object rawRuns = Wire.optional(object, "runs");
        if (!Wire.isMissing(rawRuns)) {
            builder.runs(Wire.array(rawRuns, "ConversationPart.runs", item -> ConversationTextRun.fromWire(item)));
        }
        Object rawSession = Wire.optional(object, "session");
        if (!Wire.isMissing(rawSession)) {
            builder.session(Wire.string(rawSession, "ConversationPart.session"));
        }
        Object rawStatus = Wire.optional(object, "status");
        if (!Wire.isMissing(rawStatus)) {
            builder.status(Wire.string(rawStatus, "ConversationPart.status"));
        }
        Object rawText = Wire.optional(object, "text");
        if (!Wire.isMissing(rawText)) {
            builder.text(Wire.string(rawText, "ConversationPart.text"));
        }
        Object rawType = Wire.required(object, "type");
        builder.type(Wire.string(rawType, "ConversationPart.type"));
        List<String> known = List.of("host", "preview", "runs", "session", "status", "text", "type");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "host", host);
        Wire.put(object, "preview", preview);
        Wire.put(object, "runs", runs);
        Wire.put(object, "session", session);
        Wire.put(object, "status", status);
        Wire.put(object, "text", text);
        Wire.put(object, "type", type);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationPart that)) return false;
        return Objects.equals(host, that.host) && Objects.equals(preview, that.preview) && Objects.equals(runs, that.runs) && Objects.equals(session, that.session) && Objects.equals(status, that.status) && Objects.equals(text, that.text) && Objects.equals(type, that.type) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(host, preview, runs, session, status, text, type, additionalProperties); }

    @Override
    public String toString() { return "ConversationPart" + toWire(); }

    public static final class Builder {
        private Field<String> host = Field.omitted();
        private Field<Object> preview = Field.omitted();
        private Field<List<ConversationTextRun>> runs = Field.omitted();
        private Field<String> session = Field.omitted();
        private Field<String> status = Field.omitted();
        private Field<String> text = Field.omitted();
        private String type;
        private boolean typeSet;
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder host(String value) {
            this.host = Field.of(value);
            return this;
        }
        public Builder preview(Object value) {
            this.preview = Field.of(value);
            return this;
        }
        public Builder runs(List<ConversationTextRun> value) {
            this.runs = Field.of(value);
            return this;
        }
        public Builder session(String value) {
            this.session = Field.of(value);
            return this;
        }
        public Builder status(String value) {
            this.status = Field.of(value);
            return this;
        }
        public Builder text(String value) {
            this.text = Field.of(value);
            return this;
        }
        public Builder type(String value) {
            this.type = value;
            this.typeSet = true;
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public ConversationPart build() { return new ConversationPart(this); }
    }
}
