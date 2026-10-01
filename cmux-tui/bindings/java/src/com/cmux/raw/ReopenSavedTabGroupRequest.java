// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable reopen-saved-tab-group request. Protocol v12; authority: control. */
public final class ReopenSavedTabGroupRequest implements WireValue {
    private final Object pane;
    private final String saved;
    private final Field<String> transaction;

    private ReopenSavedTabGroupRequest(Builder builder) {
        if (!builder.paneSet) throw new IllegalArgumentException("pane is required");
        this.pane = Wire.nonNull(builder.pane, "pane");
        if (!builder.savedSet) throw new IllegalArgumentException("saved is required");
        this.saved = Wire.nonNull(builder.saved, "saved");
        this.transaction = builder.transaction;
    }

    public static Builder builder() { return new Builder(); }

    public Object pane() { return pane; }
    public String saved() { return saved; }
    public Field<String> transaction() { return transaction; }

    public static ReopenSavedTabGroupRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ReopenSavedTabGroupRequest");
        Builder builder = builder();
        Object rawPane = Wire.required(object, "pane");
        builder.pane(Wire.immutableJson(rawPane));
        Object rawSaved = Wire.required(object, "saved");
        builder.saved(Wire.string(rawSaved, "ReopenSavedTabGroupRequest.saved"));
        Object rawTransaction = Wire.optional(object, "transaction");
        if (!Wire.isMissing(rawTransaction)) {
            builder.transaction(rawTransaction == null ? null : Wire.string(rawTransaction, "ReopenSavedTabGroupRequest.transaction"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "pane", pane);
        Wire.put(object, "saved", saved);
        Wire.put(object, "transaction", transaction);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ReopenSavedTabGroupRequest that)) return false;
        return Objects.equals(pane, that.pane) && Objects.equals(saved, that.saved) && Objects.equals(transaction, that.transaction);
    }

    @Override
    public int hashCode() { return Objects.hash(pane, saved, transaction); }

    @Override
    public String toString() { return "ReopenSavedTabGroupRequest" + toWire(); }

    public static final class Builder {
        private Object pane;
        private boolean paneSet;
        private String saved;
        private boolean savedSet;
        private Field<String> transaction = Field.omitted();

        public Builder pane(Object value) {
            this.pane = value;
            this.paneSet = true;
            return this;
        }
        public Builder saved(String value) {
            this.saved = value;
            this.savedSet = true;
            return this;
        }
        public Builder transaction(String value) {
            this.transaction = Field.ofNullable(value);
            return this;
        }
        public ReopenSavedTabGroupRequest build() { return new ReopenSavedTabGroupRequest(this); }
    }
}
