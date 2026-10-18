// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class ConversationTabSplit implements WireValue {
    /** The side of pane the new pane takes: right, down, left or up. */
    private final String direction;
    /** Caller-minted public id of the new pane (pane_ and 32 hex digits), as split-client-keys-v1; refused when it exists or ever existed. */
    private final Field<String> paneId;

    private ConversationTabSplit(Builder builder) {
        if (!builder.directionSet) throw new IllegalArgumentException("direction is required");
        this.direction = Wire.nonNull(builder.direction, "direction");
        this.paneId = builder.paneId;
    }

    public static Builder builder() { return new Builder(); }

    public String direction() { return direction; }
    public Field<String> paneId() { return paneId; }

    public static ConversationTabSplit fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ConversationTabSplit");
        Builder builder = builder();
        Object rawDirection = Wire.required(object, "direction");
        builder.direction(Wire.string(rawDirection, "ConversationTabSplit.direction"));
        Object rawPaneId = Wire.optional(object, "pane_id");
        if (!Wire.isMissing(rawPaneId)) {
            builder.paneId(rawPaneId == null ? null : Wire.string(rawPaneId, "ConversationTabSplit.pane_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "direction", direction);
        Wire.put(object, "pane_id", paneId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ConversationTabSplit that)) return false;
        return Objects.equals(direction, that.direction) && Objects.equals(paneId, that.paneId);
    }

    @Override
    public int hashCode() { return Objects.hash(direction, paneId); }

    @Override
    public String toString() { return "ConversationTabSplit" + toWire(); }

    public static final class Builder {
        private String direction;
        private boolean directionSet;
        private Field<String> paneId = Field.omitted();

        public Builder direction(String value) {
            this.direction = value;
            this.directionSet = true;
            return this;
        }
        public Builder paneId(String value) {
            this.paneId = Field.ofNullable(value);
            return this;
        }
        public ConversationTabSplit build() { return new ConversationTabSplit(this); }
    }
}
