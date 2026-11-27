// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable live-auto request. Protocol v12; authority: local-admin. */
public final class LiveAutoRequest implements WireValue {
    private final String op;
    private final Field<String> worktree;

    private LiveAutoRequest(Builder builder) {
        if (!builder.opSet) throw new IllegalArgumentException("op is required");
        this.op = Wire.nonNull(builder.op, "op");
        this.worktree = builder.worktree;
    }

    public static Builder builder() { return new Builder(); }

    public String op() { return op; }
    public Field<String> worktree() { return worktree; }

    public static LiveAutoRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "LiveAutoRequest");
        Builder builder = builder();
        Object rawOp = Wire.required(object, "op");
        builder.op(Wire.string(rawOp, "LiveAutoRequest.op"));
        Object rawWorktree = Wire.optional(object, "worktree");
        if (!Wire.isMissing(rawWorktree)) {
            builder.worktree(rawWorktree == null ? null : Wire.string(rawWorktree, "LiveAutoRequest.worktree"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "op", op);
        Wire.put(object, "worktree", worktree);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof LiveAutoRequest that)) return false;
        return Objects.equals(op, that.op) && Objects.equals(worktree, that.worktree);
    }

    @Override
    public int hashCode() { return Objects.hash(op, worktree); }

    @Override
    public String toString() { return "LiveAutoRequest" + toWire(); }

    public static final class Builder {
        private String op;
        private boolean opSet;
        private Field<String> worktree = Field.omitted();

        public Builder op(String value) {
            this.op = value;
            this.opSet = true;
            return this;
        }
        public Builder worktree(String value) {
            this.worktree = Field.ofNullable(value);
            return this;
        }
        public LiveAutoRequest build() { return new LiveAutoRequest(this); }
    }
}
