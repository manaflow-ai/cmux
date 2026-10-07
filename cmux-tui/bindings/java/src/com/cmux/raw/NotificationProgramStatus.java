// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class NotificationProgramStatus implements WireValue {
    private final NotificationProgramStatusKind kind;
    private final String msg;
    private final NotificationProgramStatusState state;

    private NotificationProgramStatus(Builder builder) {
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = builder.kind;
        if (!builder.msgSet) throw new IllegalArgumentException("msg is required");
        this.msg = builder.msg;
        if (!builder.stateSet) throw new IllegalArgumentException("state is required");
        this.state = Wire.nonNull(builder.state, "state");
    }

    public static Builder builder() { return new Builder(); }

    public NotificationProgramStatusKind kind() { return kind; }
    public String msg() { return msg; }
    public NotificationProgramStatusState state() { return state; }

    public static NotificationProgramStatus fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "NotificationProgramStatus");
        Builder builder = builder();
        Object rawKind = Wire.required(object, "kind");
        builder.kind(rawKind == null ? null : NotificationProgramStatusKind.fromWire(rawKind));
        Object rawMsg = Wire.required(object, "msg");
        builder.msg(rawMsg == null ? null : Wire.string(rawMsg, "NotificationProgramStatus.msg"));
        Object rawState = Wire.required(object, "state");
        builder.state(NotificationProgramStatusState.fromWire(rawState));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "kind", kind);
        Wire.put(object, "msg", msg);
        Wire.put(object, "state", state);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof NotificationProgramStatus that)) return false;
        return Objects.equals(kind, that.kind) && Objects.equals(msg, that.msg) && Objects.equals(state, that.state);
    }

    @Override
    public int hashCode() { return Objects.hash(kind, msg, state); }

    @Override
    public String toString() { return "NotificationProgramStatus" + toWire(); }

    public static final class Builder {
        private NotificationProgramStatusKind kind;
        private boolean kindSet;
        private String msg;
        private boolean msgSet;
        private NotificationProgramStatusState state;
        private boolean stateSet;

        public Builder kind(NotificationProgramStatusKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder msg(String value) {
            this.msg = value;
            this.msgSet = true;
            return this;
        }
        public Builder state(NotificationProgramStatusState value) {
            this.state = value;
            this.stateSet = true;
            return this;
        }
        public NotificationProgramStatus build() { return new NotificationProgramStatus(this); }
    }
}
