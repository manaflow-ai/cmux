// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class HistorySearchHit implements WireValue {
    private final long atMs;
    private final List<HistorySearchRange> highlights;
    private final String key;
    private final String kind;
    private final Long position;
    private final String snippet;
    private final String target;
    private final String title;

    private HistorySearchHit(Builder builder) {
        if (!builder.atMsSet) throw new IllegalArgumentException("at_ms is required");
        this.atMs = builder.atMs;
        if (!builder.highlightsSet) throw new IllegalArgumentException("highlights is required");
        this.highlights = List.copyOf(Wire.nonNull(builder.highlights, "highlights"));
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        if (!builder.positionSet) throw new IllegalArgumentException("position is required");
        this.position = builder.position;
        if (!builder.snippetSet) throw new IllegalArgumentException("snippet is required");
        this.snippet = Wire.nonNull(builder.snippet, "snippet");
        if (!builder.targetSet) throw new IllegalArgumentException("target is required");
        this.target = Wire.nonNull(builder.target, "target");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = Wire.nonNull(builder.title, "title");
    }

    public static Builder builder() { return new Builder(); }

    public long atMs() { return atMs; }
    public List<HistorySearchRange> highlights() { return highlights; }
    public String key() { return key; }
    public String kind() { return kind; }
    public Long position() { return position; }
    public String snippet() { return snippet; }
    public String target() { return target; }
    public String title() { return title; }

    public static HistorySearchHit fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "HistorySearchHit");
        Builder builder = builder();
        Object rawAtMs = Wire.required(object, "at_ms");
        builder.atMs(Wire.int64(rawAtMs, "HistorySearchHit.at_ms"));
        Object rawHighlights = Wire.required(object, "highlights");
        builder.highlights(Wire.array(rawHighlights, "HistorySearchHit.highlights", item -> HistorySearchRange.fromWire(item)));
        Object rawKey = Wire.required(object, "key");
        builder.key(Wire.string(rawKey, "HistorySearchHit.key"));
        Object rawKind = Wire.required(object, "kind");
        builder.kind(Wire.string(rawKind, "HistorySearchHit.kind"));
        Object rawPosition = Wire.required(object, "position");
        builder.position(rawPosition == null ? null : Wire.int64(rawPosition, "HistorySearchHit.position"));
        Object rawSnippet = Wire.required(object, "snippet");
        builder.snippet(Wire.string(rawSnippet, "HistorySearchHit.snippet"));
        Object rawTarget = Wire.required(object, "target");
        builder.target(Wire.string(rawTarget, "HistorySearchHit.target"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(Wire.string(rawTitle, "HistorySearchHit.title"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "at_ms", atMs);
        Wire.put(object, "highlights", highlights);
        Wire.put(object, "key", key);
        Wire.put(object, "kind", kind);
        Wire.put(object, "position", position);
        Wire.put(object, "snippet", snippet);
        Wire.put(object, "target", target);
        Wire.put(object, "title", title);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof HistorySearchHit that)) return false;
        return Objects.equals(atMs, that.atMs) && Objects.equals(highlights, that.highlights) && Objects.equals(key, that.key) && Objects.equals(kind, that.kind) && Objects.equals(position, that.position) && Objects.equals(snippet, that.snippet) && Objects.equals(target, that.target) && Objects.equals(title, that.title);
    }

    @Override
    public int hashCode() { return Objects.hash(atMs, highlights, key, kind, position, snippet, target, title); }

    @Override
    public String toString() { return "HistorySearchHit" + toWire(); }

    public static final class Builder {
        private Long atMs;
        private boolean atMsSet;
        private List<HistorySearchRange> highlights;
        private boolean highlightsSet;
        private String key;
        private boolean keySet;
        private String kind;
        private boolean kindSet;
        private Long position;
        private boolean positionSet;
        private String snippet;
        private boolean snippetSet;
        private String target;
        private boolean targetSet;
        private String title;
        private boolean titleSet;

        public Builder atMs(long value) {
            this.atMs = value;
            this.atMsSet = true;
            return this;
        }
        public Builder highlights(List<HistorySearchRange> value) {
            this.highlights = value;
            this.highlightsSet = true;
            return this;
        }
        public Builder key(String value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder kind(String value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder position(Long value) {
            this.position = value;
            this.positionSet = true;
            return this;
        }
        public Builder snippet(String value) {
            this.snippet = value;
            this.snippetSet = true;
            return this;
        }
        public Builder target(String value) {
            this.target = value;
            this.targetSet = true;
            return this;
        }
        public Builder title(String value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public HistorySearchHit build() { return new HistorySearchHit(this); }
    }
}
