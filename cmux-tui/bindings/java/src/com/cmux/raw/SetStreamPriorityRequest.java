// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable set-stream-priority request. Protocol v12; authority: frontend. */
public final class SetStreamPriorityRequest implements WireValue {
    private final SetStreamPriorityRequestPriority priority;
    private final int stream;

    private SetStreamPriorityRequest(Builder builder) {
        if (!builder.prioritySet) throw new IllegalArgumentException("priority is required");
        this.priority = Wire.nonNull(builder.priority, "priority");
        if (!builder.streamSet) throw new IllegalArgumentException("stream is required");
        this.stream = builder.stream;
    }

    public static Builder builder() { return new Builder(); }

    public SetStreamPriorityRequestPriority priority() { return priority; }
    public int stream() { return stream; }

    public static SetStreamPriorityRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "SetStreamPriorityRequest");
        Builder builder = builder();
        Object rawPriority = Wire.required(object, "priority");
        builder.priority(SetStreamPriorityRequestPriority.fromWire(rawPriority));
        Object rawStream = Wire.required(object, "stream");
        builder.stream(Wire.uint16(rawStream, "SetStreamPriorityRequest.stream"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "priority", priority);
        Wire.put(object, "stream", stream);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof SetStreamPriorityRequest that)) return false;
        return Objects.equals(priority, that.priority) && Objects.equals(stream, that.stream);
    }

    @Override
    public int hashCode() { return Objects.hash(priority, stream); }

    @Override
    public String toString() { return "SetStreamPriorityRequest" + toWire(); }

    public static final class Builder {
        private SetStreamPriorityRequestPriority priority;
        private boolean prioritySet;
        private Integer stream;
        private boolean streamSet;

        public Builder priority(SetStreamPriorityRequestPriority value) {
            this.priority = value;
            this.prioritySet = true;
            return this;
        }
        public Builder stream(int value) {
            this.stream = value;
            this.streamSet = true;
            return this;
        }
        public SetStreamPriorityRequest build() { return new SetStreamPriorityRequest(this); }
    }
}
