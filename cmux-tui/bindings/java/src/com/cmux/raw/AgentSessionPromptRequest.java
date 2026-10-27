// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable agent-session-prompt request. Protocol v12; authority: local-admin. */
public final class AgentSessionPromptRequest implements WireValue {
    /** 1 to 128 letters, digits, '-' or '_'. */
    private final String promptId;
    /** The agent chat tab: an agent_session tab of this daemon's store. */
    private final UInt64 surface;
    /** One text prompt, at most 64 KiB. */
    private final String text;

    private AgentSessionPromptRequest(Builder builder) {
        if (!builder.promptIdSet) throw new IllegalArgumentException("prompt_id is required");
        this.promptId = Wire.nonNull(builder.promptId, "prompt_id");
        if (!builder.surfaceSet) throw new IllegalArgumentException("surface is required");
        this.surface = Wire.nonNull(builder.surface, "surface");
        if (!builder.textSet) throw new IllegalArgumentException("text is required");
        this.text = Wire.nonNull(builder.text, "text");
    }

    public static Builder builder() { return new Builder(); }

    public String promptId() { return promptId; }
    public UInt64 surface() { return surface; }
    public String text() { return text; }

    public static AgentSessionPromptRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "AgentSessionPromptRequest");
        Builder builder = builder();
        Object rawPromptId = Wire.required(object, "prompt_id");
        builder.promptId(Wire.string(rawPromptId, "AgentSessionPromptRequest.prompt_id"));
        Object rawSurface = Wire.required(object, "surface");
        builder.surface(Wire.uint64(rawSurface, "AgentSessionPromptRequest.surface"));
        Object rawText = Wire.required(object, "text");
        builder.text(Wire.string(rawText, "AgentSessionPromptRequest.text"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "prompt_id", promptId);
        Wire.put(object, "surface", surface);
        Wire.put(object, "text", text);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof AgentSessionPromptRequest that)) return false;
        return Objects.equals(promptId, that.promptId) && Objects.equals(surface, that.surface) && Objects.equals(text, that.text);
    }

    @Override
    public int hashCode() { return Objects.hash(promptId, surface, text); }

    @Override
    public String toString() { return "AgentSessionPromptRequest" + toWire(); }

    public static final class Builder {
        private String promptId;
        private boolean promptIdSet;
        private UInt64 surface;
        private boolean surfaceSet;
        private String text;
        private boolean textSet;

        public Builder promptId(String value) {
            this.promptId = value;
            this.promptIdSet = true;
            return this;
        }
        public Builder surface(UInt64 value) {
            this.surface = value;
            this.surfaceSet = true;
            return this;
        }
        public Builder text(String value) {
            this.text = value;
            this.textSet = true;
            return this;
        }
        public AgentSessionPromptRequest build() { return new AgentSessionPromptRequest(this); }
    }
}
