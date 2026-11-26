// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable terminal-find request. Protocol v7; authority: control. */
public final class TerminalFindRequest implements WireValue {
    /** Marker the page ends above (exclusive): the previous page's next_before. */
    private final Field<UInt64> before;
    private final Field<Boolean> caseSensitive;
    /** The previous page's epoch; a different one restarts at the bottom. */
    private final Field<UInt64> epoch;
    private final Field<UInt64> maxMatches;
    private final Field<UInt64> pageRows;
    /** Empty matches nothing. */
    private final String query;
    /** query is a Rust regex pattern, not a literal. */
    private final Field<Boolean> regex;
    private final UInt64 surface;
    private final Field<Boolean> wholeWord;

    private TerminalFindRequest(Builder builder) {
        this.before = builder.before;
        this.caseSensitive = builder.caseSensitive;
        this.epoch = builder.epoch;
        this.maxMatches = builder.maxMatches;
        this.pageRows = builder.pageRows;
        if (!builder.querySet) throw new IllegalArgumentException("query is required");
        this.query = Wire.nonNull(builder.query, "query");
        this.regex = builder.regex;
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        this.wholeWord = builder.wholeWord;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> before() { return before; }
    public Field<Boolean> caseSensitive() { return caseSensitive; }
    public Field<UInt64> epoch() { return epoch; }
    public Field<UInt64> maxMatches() { return maxMatches; }
    public Field<UInt64> pageRows() { return pageRows; }
    public String query() { return query; }
    public Field<Boolean> regex() { return regex; }
    public UInt64 surface() { return surface; }
    public Field<Boolean> wholeWord() { return wholeWord; }

    public static TerminalFindRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalFindRequest");
        Builder builder = builder();
        Object rawBefore = Wire.optional(object, "before");
        if (!Wire.isMissing(rawBefore)) {
            builder.before(rawBefore == null ? null : Wire.uint64(rawBefore, "TerminalFindRequest.before"));
        }
        Object rawCaseSensitive = Wire.optional(object, "case_sensitive");
        if (!Wire.isMissing(rawCaseSensitive)) {
            builder.caseSensitive(Wire.bool(rawCaseSensitive, "TerminalFindRequest.case_sensitive"));
        }
        Object rawEpoch = Wire.optional(object, "epoch");
        if (!Wire.isMissing(rawEpoch)) {
            builder.epoch(rawEpoch == null ? null : Wire.uint64(rawEpoch, "TerminalFindRequest.epoch"));
        }
        Object rawMaxMatches = Wire.optional(object, "max_matches");
        if (!Wire.isMissing(rawMaxMatches)) {
            builder.maxMatches(rawMaxMatches == null ? null : Wire.uint64(rawMaxMatches, "TerminalFindRequest.max_matches"));
        }
        Object rawPageRows = Wire.optional(object, "page_rows");
        if (!Wire.isMissing(rawPageRows)) {
            builder.pageRows(rawPageRows == null ? null : Wire.uint64(rawPageRows, "TerminalFindRequest.page_rows"));
        }
        Object rawQuery = Wire.required(object, "query");
        builder.query(Wire.string(rawQuery, "TerminalFindRequest.query"));
        Object rawRegex = Wire.optional(object, "regex");
        if (!Wire.isMissing(rawRegex)) {
            builder.regex(Wire.bool(rawRegex, "TerminalFindRequest.regex"));
        }
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "TerminalFindRequest.surface"));
        Object rawWholeWord = Wire.optional(object, "whole_word");
        if (!Wire.isMissing(rawWholeWord)) {
            builder.wholeWord(Wire.bool(rawWholeWord, "TerminalFindRequest.whole_word"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "before", before);
        Wire.put(object, "case_sensitive", caseSensitive);
        Wire.put(object, "epoch", epoch);
        Wire.put(object, "max_matches", maxMatches);
        Wire.put(object, "page_rows", pageRows);
        Wire.put(object, "query", query);
        Wire.put(object, "regex", regex);
        Wire.put(object, "surface", surface);
        Wire.put(object, "whole_word", wholeWord);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalFindRequest that)) return false;
        return Objects.equals(before, that.before) && Objects.equals(caseSensitive, that.caseSensitive) && Objects.equals(epoch, that.epoch) && Objects.equals(maxMatches, that.maxMatches) && Objects.equals(pageRows, that.pageRows) && Objects.equals(query, that.query) && Objects.equals(regex, that.regex) && Objects.equals(surface, that.surface) && Objects.equals(wholeWord, that.wholeWord);
    }

    @Override
    public int hashCode() { return Objects.hash(before, caseSensitive, epoch, maxMatches, pageRows, query, regex, surface, wholeWord); }

    @Override
    public String toString() { return "TerminalFindRequest" + toWire(); }

    public static final class Builder {
        private Field<UInt64> before = Field.omitted();
        private Field<Boolean> caseSensitive = Field.omitted();
        private Field<UInt64> epoch = Field.omitted();
        private Field<UInt64> maxMatches = Field.omitted();
        private Field<UInt64> pageRows = Field.omitted();
        private String query;
        private boolean querySet;
        private Field<Boolean> regex = Field.omitted();
        private UInt64 surface;
        private boolean surfaceSet;
        private Field<Boolean> wholeWord = Field.omitted();

        public Builder before(UInt64 value) {
            this.before = Field.ofNullable(value);
            return this;
        }
        public Builder caseSensitive(Boolean value) {
            this.caseSensitive = Field.of(value);
            return this;
        }
        public Builder epoch(UInt64 value) {
            this.epoch = Field.ofNullable(value);
            return this;
        }
        public Builder maxMatches(UInt64 value) {
            this.maxMatches = Field.ofNullable(value);
            return this;
        }
        public Builder pageRows(UInt64 value) {
            this.pageRows = Field.ofNullable(value);
            return this;
        }
        public Builder query(String value) {
            this.query = value;
            this.querySet = true;
            return this;
        }
        public Builder regex(Boolean value) {
            this.regex = Field.of(value);
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder wholeWord(Boolean value) {
            this.wholeWord = Field.of(value);
            return this;
        }
        public TerminalFindRequest build() { return new TerminalFindRequest(this); }
    }
}
