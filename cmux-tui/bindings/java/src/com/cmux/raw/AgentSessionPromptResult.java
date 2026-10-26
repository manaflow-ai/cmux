// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class AgentSessionPromptResult implements WireValue {
    private final String promptId;
    /** acpmux queued the prompt behind a running turn. */
    private final boolean queued;
    /** The turn acpmux started or queued, as it answered. */
    private final String turnId;

    private AgentSessionPromptResult(Builder builder) {
        if (!builder.promptIdSet) throw new IllegalArgumentException("prompt_id is required");
        this.promptId = Wire.nonNull(builder.promptId, "prompt_id");
        if (!builder.queuedSet) throw new IllegalArgumentException("queued is required");
        this.queued = builder.queued;
        if (!builder.turnIdSet) throw new IllegalArgumentException("turn_id is required");
        this.turnId = builder.turnId;
    }

    public static Builder builder() { return new Builder(); }

    public String promptId() { return promptId; }
    public boolean queued() { return queued; }
    public String turnId() { return turnId; }

    public static AgentSessionPromptResult fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionPromptResult");
        Builder builder = builder();
        Object rawPromptId = Wire.required(object, "prompt_id");
        builder.promptId(Wire.string(rawPromptId, "AgentSessionPromptResult.prompt_id"));
        Object rawQueued = Wire.required(object, "queued");
        builder.queued(Wire.bool(rawQueued, "AgentSessionPromptResult.queued"));
        Object rawTurnId = Wire.required(object, "turn_id");
        builder.turnId(rawTurnId == null ? null : Wire.string(rawTurnId, "AgentSessionPromptResult.turn_id"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "prompt_id", promptId);
        Wire.put(object, "queued", queued);
        Wire.put(object, "turn_id", turnId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionPromptResult that)) return false;
        return Objects.equals(promptId, that.promptId) && Objects.equals(queued, that.queued) && Objects.equals(turnId, that.turnId);
    }

    @Override
    public int hashCode() { return Objects.hash(promptId, queued, turnId); }

    @Override
    public String toString() { return "AgentSessionPromptResult" + toWire(); }

    public static final class Builder {
        private String promptId;
        private boolean promptIdSet;
        private Boolean queued;
        private boolean queuedSet;
        private String turnId;
        private boolean turnIdSet;

        public Builder promptId(String value) {
            this.promptId = value;
            this.promptIdSet = true;
            return this;
        }
        public Builder queued(boolean value) {
            this.queued = value;
            this.queuedSet = true;
            return this;
        }
        public Builder turnId(String value) {
            this.turnId = value;
            this.turnIdSet = true;
            return this;
        }
        public AgentSessionPromptResult build() { return new AgentSessionPromptResult(this); }
    }
}
