// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AppPaletteCommand implements WireValue {
    private final String op;
    private final Object title;
    private final Field<Object> when;

    private AppPaletteCommand(Builder builder) {
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = Wire.nonNull(builder.op, "op");
        if (!builder.titleSet) throw new IllegalArgumentException("title is required");
        this.title = builder.title == null ? null : Wire.immutableJson(builder.title);
        this.when = builder.when.map(value -> Wire.immutableJson(value));
    }

    public static Builder builder() { return new Builder(); }

    public String op() { return op; }
    public Object title() { return title; }
    public Field<Object> when() { return when; }

    public static AppPaletteCommand fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AppPaletteCommand");
        Builder builder = builder();
        Object rawOp = Wire.required(object, "op");
        builder.op(Wire.string(rawOp, "AppPaletteCommand.op"));
        Object rawTitle = Wire.required(object, "title");
        builder.title(rawTitle == null ? null : Wire.immutableJson(rawTitle));
        Object rawWhen = Wire.optional(object, "when");
        if (!Wire.isMissing(rawWhen)) {
            builder.when(rawWhen == null ? null : Wire.immutableJson(rawWhen));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "op", op);
        Wire.put(object, "title", title);
        Wire.put(object, "when", when);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AppPaletteCommand that)) return false;
        return Objects.equals(op, that.op) && Objects.equals(title, that.title) && Objects.equals(when, that.when);
    }

    @Override
    public int hashCode() { return Objects.hash(op, title, when); }

    @Override
    public String toString() { return "AppPaletteCommand" + toWire(); }

    public static final class Builder {
        private String op;
        private boolean opSet;
        private Object title;
        private boolean titleSet;
        private Field<Object> when = Field.omitted();

        public Builder op(String value) {
            this.op = value;
            this.opSet = true;
            return this;
        }
        public Builder title(Object value) {
            this.title = value;
            this.titleSet = true;
            return this;
        }
        public Builder when(Object value) {
            this.when = Field.ofNullable(value);
            return this;
        }
        public AppPaletteCommand build() { return new AppPaletteCommand(this); }
    }
}
