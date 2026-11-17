// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TabPlace implements WireValue {
    /** Right after this tab of pane. */
    private final Field<UInt64> after;
    /** Right after the tab of an earlier create request of this connection for pane: the transaction of that request (1 to 128 printable ASCII). That tab does not have to be there yet. */
    private final Field<String> afterCreation;
    /** Right before this tab of pane. */
    private final Field<UInt64> before;
    /** true: the tab joins the tab group of the tab that after, after_creation or before names. Refused with start. */
    private final Field<Boolean> joins;
    /** true: the first tab after the pinned tabs. */
    private final Field<Boolean> start;

    private TabPlace(Builder builder) {
        this.after = builder.after;
        this.afterCreation = builder.afterCreation;
        this.before = builder.before;
        this.joins = builder.joins;
        this.start = builder.start;
    }

    public static Builder builder() { return new Builder(); }

    public Field<UInt64> after() { return after; }
    public Field<String> afterCreation() { return afterCreation; }
    public Field<UInt64> before() { return before; }
    public Field<Boolean> joins() { return joins; }
    public Field<Boolean> start() { return start; }

    public static TabPlace fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TabPlace");
        Builder builder = builder();
        Object rawAfter = Wire.optional(object, "after");
        if (!Wire.isMissing(rawAfter)) {
            builder.after(rawAfter == null ? null : Wire.uint64(rawAfter, "TabPlace.after"));
        }
        Object rawAfterCreation = Wire.optional(object, "after_creation");
        if (!Wire.isMissing(rawAfterCreation)) {
            builder.afterCreation(rawAfterCreation == null ? null : Wire.string(rawAfterCreation, "TabPlace.after_creation"));
        }
        Object rawBefore = Wire.optional(object, "before");
        if (!Wire.isMissing(rawBefore)) {
            builder.before(rawBefore == null ? null : Wire.uint64(rawBefore, "TabPlace.before"));
        }
        Object rawJoins = Wire.optional(object, "joins");
        if (!Wire.isMissing(rawJoins)) {
            builder.joins(rawJoins == null ? null : Wire.bool(rawJoins, "TabPlace.joins"));
        }
        Object rawStart = Wire.optional(object, "start");
        if (!Wire.isMissing(rawStart)) {
            builder.start(rawStart == null ? null : Wire.bool(rawStart, "TabPlace.start"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "after", after);
        Wire.put(object, "after_creation", afterCreation);
        Wire.put(object, "before", before);
        Wire.put(object, "joins", joins);
        Wire.put(object, "start", start);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TabPlace that)) return false;
        return Objects.equals(after, that.after) && Objects.equals(afterCreation, that.afterCreation) && Objects.equals(before, that.before) && Objects.equals(joins, that.joins) && Objects.equals(start, that.start);
    }

    @Override
    public int hashCode() { return Objects.hash(after, afterCreation, before, joins, start); }

    @Override
    public String toString() { return "TabPlace" + toWire(); }

    public static final class Builder {
        private Field<UInt64> after = Field.omitted();
        private Field<String> afterCreation = Field.omitted();
        private Field<UInt64> before = Field.omitted();
        private Field<Boolean> joins = Field.omitted();
        private Field<Boolean> start = Field.omitted();

        public Builder after(UInt64 value) {
            this.after = Field.ofNullable(value);
            return this;
        }
        public Builder afterCreation(String value) {
            this.afterCreation = Field.ofNullable(value);
            return this;
        }
        public Builder before(UInt64 value) {
            this.before = Field.ofNullable(value);
            return this;
        }
        public Builder joins(Boolean value) {
            this.joins = Field.ofNullable(value);
            return this;
        }
        public Builder start(Boolean value) {
            this.start = Field.ofNullable(value);
            return this;
        }
        public TabPlace build() { return new TabPlace(this); }
    }
}
