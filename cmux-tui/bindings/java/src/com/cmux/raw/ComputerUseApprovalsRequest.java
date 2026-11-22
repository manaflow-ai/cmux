// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


/** Immutable computer-use-approvals request. Protocol v12; authority: local-admin. */
public final class ComputerUseApprovalsRequest implements WireValue {
    private final String action;
    private final Field<String> answer;
    private final Field<String> appId;

    private ComputerUseApprovalsRequest(Builder builder) {
        if (!builder.actionSet) throw new IllegalArgumentException("action is required");
        this.action = Wire.nonNull(builder.action, "action");
        this.answer = builder.answer;
        this.appId = builder.appId;
    }

    public static Builder builder() { return new Builder(); }

    public String action() { return action; }
    public Field<String> answer() { return answer; }
    public Field<String> appId() { return appId; }

    public static ComputerUseApprovalsRequest fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "ComputerUseApprovalsRequest");
        Builder builder = builder();
        Object rawAction = Wire.required(object, "action");
        builder.action(Wire.string(rawAction, "ComputerUseApprovalsRequest.action"));
        Object rawAnswer = Wire.optional(object, "answer");
        if (!Wire.isMissing(rawAnswer)) {
            builder.answer(rawAnswer == null ? null : Wire.string(rawAnswer, "ComputerUseApprovalsRequest.answer"));
        }
        Object rawAppId = Wire.optional(object, "app_id");
        if (!Wire.isMissing(rawAppId)) {
            builder.appId(rawAppId == null ? null : Wire.string(rawAppId, "ComputerUseApprovalsRequest.app_id"));
        }
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "action", action);
        Wire.put(object, "answer", answer);
        Wire.put(object, "app_id", appId);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof ComputerUseApprovalsRequest that)) return false;
        return Objects.equals(action, that.action) && Objects.equals(answer, that.answer) && Objects.equals(appId, that.appId);
    }

    @Override
    public int hashCode() { return Objects.hash(action, answer, appId); }

    @Override
    public String toString() { return "ComputerUseApprovalsRequest" + toWire(); }

    public static final class Builder {
        private String action;
        private boolean actionSet;
        private Field<String> answer = Field.omitted();
        private Field<String> appId = Field.omitted();

        public Builder action(String value) {
            this.action = value;
            this.actionSet = true;
            return this;
        }
        public Builder answer(String value) {
            this.answer = Field.ofNullable(value);
            return this;
        }
        public Builder appId(String value) {
            this.appId = Field.ofNullable(value);
            return this;
        }
        public ComputerUseApprovalsRequest build() { return new ComputerUseApprovalsRequest(this); }
    }
}
