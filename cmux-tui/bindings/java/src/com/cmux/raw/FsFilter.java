// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class FsFilter implements WireValue {
    private final Field<Boolean> hidden;
    private final Field<List<FsEntryKind>> kinds;
    private final Field<String> query;

    private FsFilter(Builder builder) {
        this.hidden = builder.hidden;
        this.kinds = builder.kinds.map(value -> List.copyOf(value));
        this.query = builder.query;
    }

    public static Builder builder() { return new Builder(); }

    public Field<Boolean> hidden() { return hidden; }
    public Field<List<FsEntryKind>> kinds() { return kinds; }
    public Field<String> query() { return query; }

    public static FsFilter fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "FsFilter");
        Builder builder = builder();
        Object rawHidden = Wire.optional(object, "hidden");
        if (!Wire.isMissing(rawHidden)) {
            builder.hidden(Wire.bool(rawHidden, "FsFilter.hidden"));
        }
        Object rawKinds = Wire.optional(object, "kinds");
        if (!Wire.isMissing(rawKinds)) {
            builder.kinds(rawKinds == null ? null : Wire.array(rawKinds, "FsFilter.kinds", item -> FsEntryKind.fromWire(item)));
        }
        Object rawQuery = Wire.optional(object, "query");
        if (!Wire.isMissing(rawQuery)) {
            builder.query(rawQuery == null ? null : Wire.string(rawQuery, "FsFilter.query"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "hidden", hidden);
        Wire.put(object, "kinds", kinds);
        Wire.put(object, "query", query);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof FsFilter that)) return false;
        return Objects.equals(hidden, that.hidden) && Objects.equals(kinds, that.kinds) && Objects.equals(query, that.query);
    }

    @Override
    public int hashCode() { return Objects.hash(hidden, kinds, query); }

    @Override
    public String toString() { return "FsFilter" + toWire(); }

    public static final class Builder {
        private Field<Boolean> hidden = Field.omitted();
        private Field<List<FsEntryKind>> kinds = Field.omitted();
        private Field<String> query = Field.omitted();

        public Builder hidden(Boolean value) {
            this.hidden = Field.of(value);
            return this;
        }
        public Builder kinds(List<FsEntryKind> value) {
            this.kinds = Field.ofNullable(value);
            return this;
        }
        public Builder query(String value) {
            this.query = Field.ofNullable(value);
            return this;
        }
        public FsFilter build() { return new FsFilter(this); }
    }
}
