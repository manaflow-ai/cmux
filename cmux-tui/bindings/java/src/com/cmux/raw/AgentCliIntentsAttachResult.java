// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentCliIntentsAttachResult implements WireValue {
    private final boolean changed;
    private final AgentCLIStoredIntent intent;

    private AgentCliIntentsAttachResult(Builder builder) {
        if (!builder.changedSet) throw new IllegalArgumentException("changed is required");
        this.changed = builder.changed;
        if (!builder.intentSet) throw new IllegalArgumentException("intent is required");
        this.intent = Wire.nonNull(builder.intent, "intent");
    }

    public static Builder builder() { return new Builder(); }

    public boolean changed() { return changed; }
    public AgentCLIStoredIntent intent() { return intent; }

    public static AgentCliIntentsAttachResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentCliIntentsAttachResult");
        Builder builder = builder();
        Object rawChanged = Wire.required(object, "changed");
        builder.changed(Wire.bool(rawChanged, "AgentCliIntentsAttachResult.changed"));
        Object rawIntent = Wire.required(object, "intent");
        builder.intent(AgentCLIStoredIntent.fromWire(rawIntent));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "changed", changed);
        Wire.put(object, "intent", intent);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentCliIntentsAttachResult that)) return false;
        return Objects.equals(changed, that.changed) && Objects.equals(intent, that.intent);
    }

    @Override
    public int hashCode() { return Objects.hash(changed, intent); }

    @Override
    public String toString() { return "AgentCliIntentsAttachResult" + toWire(); }

    public static final class Builder {
        private Boolean changed;
        private boolean changedSet;
        private AgentCLIStoredIntent intent;
        private boolean intentSet;

        public Builder changed(boolean value) {
            this.changed = value;
            this.changedSet = true;
            return this;
        }
        public Builder intent(AgentCLIStoredIntent value) {
            this.intent = value;
            this.intentSet = true;
            return this;
        }
        public AgentCliIntentsAttachResult build() { return new AgentCliIntentsAttachResult(this); }
    }
}
