// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalTabEnd implements WireValue {
    /** `host_lost`: the evidence the host left (cx-0tgl), when it recorded any. */
    private final Field<TerminalLossCause> cause;
    /** `exited`: the exit code, when the host recorded one. */
    private final Field<Integer> code;
    /** `signaled`: whether the process dumped core. */
    private final Field<Boolean> coreDumped;
    /** `host_lost` and `launch_failed`, and an `exited` end with no status: free-form text. */
    private final Field<String> detail;
    private final TerminalEndKind kind;
    /** A `restart_failed` host loss: why the restart launch failed, when the detail names it. */
    private final Field<TerminalLaunchFailure> launchFailure;
    /** `host_lost`: a stable code for how the host was lost; the raw text stays in `detail`. */
    private final Field<TerminalHostLostReason> reason;
    /** `signaled`: the signal that killed the process. */
    private final Field<Integer> signal;
    private final Map<String, Object> additionalProperties;

    private TerminalTabEnd(Builder builder) {
        this.cause = builder.cause;
        this.code = builder.code;
        this.coreDumped = builder.coreDumped;
        this.detail = builder.detail;
        if (!builder.kindSet) throw new IllegalArgumentException("kind is required");
        this.kind = Wire.nonNull(builder.kind, "kind");
        this.launchFailure = builder.launchFailure;
        this.reason = builder.reason;
        this.signal = builder.signal;
        this.additionalProperties = Collections.unmodifiableMap(new LinkedHashMap<>(builder.additionalProperties));
    }

    public static Builder builder() { return new Builder(); }

    public Field<TerminalLossCause> cause() { return cause; }
    public Field<Integer> code() { return code; }
    public Field<Boolean> coreDumped() { return coreDumped; }
    public Field<String> detail() { return detail; }
    public TerminalEndKind kind() { return kind; }
    public Field<TerminalLaunchFailure> launchFailure() { return launchFailure; }
    public Field<TerminalHostLostReason> reason() { return reason; }
    public Field<Integer> signal() { return signal; }
    public Map<String, Object> additionalProperties() { return additionalProperties; }

    public static TerminalTabEnd fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalTabEnd");
        Builder builder = builder();
        Object rawCause = Wire.optional(object, "cause");
        if (!Wire.isMissing(rawCause)) {
            builder.cause(TerminalLossCause.fromWire(rawCause));
        }
        Object rawCode = Wire.optional(object, "code");
        if (!Wire.isMissing(rawCode)) {
            builder.code(Wire.int32(rawCode, "TerminalTabEnd.code"));
        }
        Object rawCoreDumped = Wire.optional(object, "core_dumped");
        if (!Wire.isMissing(rawCoreDumped)) {
            builder.coreDumped(Wire.bool(rawCoreDumped, "TerminalTabEnd.core_dumped"));
        }
        Object rawDetail = Wire.optional(object, "detail");
        if (!Wire.isMissing(rawDetail)) {
            builder.detail(Wire.string(rawDetail, "TerminalTabEnd.detail"));
        }
        Object rawKind = Wire.required(object, "kind");
        builder.kind(TerminalEndKind.fromWire(rawKind));
        Object rawLaunchFailure = Wire.optional(object, "launch_failure");
        if (!Wire.isMissing(rawLaunchFailure)) {
            builder.launchFailure(TerminalLaunchFailure.fromWire(rawLaunchFailure));
        }
        Object rawReason = Wire.optional(object, "reason");
        if (!Wire.isMissing(rawReason)) {
            builder.reason(TerminalHostLostReason.fromWire(rawReason));
        }
        Object rawSignal = Wire.optional(object, "signal");
        if (!Wire.isMissing(rawSignal)) {
            builder.signal(Wire.int32(rawSignal, "TerminalTabEnd.signal"));
        }
        List<String> known = List.of("cause", "code", "core_dumped", "detail", "kind", "launch_failure", "reason", "signal");
        object.forEach((key, item) -> { if (!known.contains(key)) builder.putAdditional(key, Wire.immutableJson(item)); });
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "cause", cause);
        Wire.put(object, "code", code);
        Wire.put(object, "core_dumped", coreDumped);
        Wire.put(object, "detail", detail);
        Wire.put(object, "kind", kind);
        Wire.put(object, "launch_failure", launchFailure);
        Wire.put(object, "reason", reason);
        Wire.put(object, "signal", signal);
        additionalProperties.forEach((key, value) -> object.putIfAbsent(key, Wire.encode(value)));
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalTabEnd that)) return false;
        return Objects.equals(cause, that.cause) && Objects.equals(code, that.code) && Objects.equals(coreDumped, that.coreDumped) && Objects.equals(detail, that.detail) && Objects.equals(kind, that.kind) && Objects.equals(launchFailure, that.launchFailure) && Objects.equals(reason, that.reason) && Objects.equals(signal, that.signal) && Objects.equals(additionalProperties, that.additionalProperties);
    }

    @Override
    public int hashCode() { return Objects.hash(cause, code, coreDumped, detail, kind, launchFailure, reason, signal, additionalProperties); }

    @Override
    public String toString() { return "TerminalTabEnd" + toWire(); }

    public static final class Builder {
        private Field<TerminalLossCause> cause = Field.omitted();
        private Field<Integer> code = Field.omitted();
        private Field<Boolean> coreDumped = Field.omitted();
        private Field<String> detail = Field.omitted();
        private TerminalEndKind kind;
        private boolean kindSet;
        private Field<TerminalLaunchFailure> launchFailure = Field.omitted();
        private Field<TerminalHostLostReason> reason = Field.omitted();
        private Field<Integer> signal = Field.omitted();
        private final LinkedHashMap<String, Object> additionalProperties = new LinkedHashMap<>();

        public Builder cause(TerminalLossCause value) {
            this.cause = Field.of(value);
            return this;
        }
        public Builder code(Integer value) {
            this.code = Field.of(value);
            return this;
        }
        public Builder coreDumped(Boolean value) {
            this.coreDumped = Field.of(value);
            return this;
        }
        public Builder detail(String value) {
            this.detail = Field.of(value);
            return this;
        }
        public Builder kind(TerminalEndKind value) {
            this.kind = value;
            this.kindSet = true;
            return this;
        }
        public Builder launchFailure(TerminalLaunchFailure value) {
            this.launchFailure = Field.of(value);
            return this;
        }
        public Builder reason(TerminalHostLostReason value) {
            this.reason = Field.of(value);
            return this;
        }
        public Builder signal(Integer value) {
            this.signal = Field.of(value);
            return this;
        }
        public Builder putAdditional(String key, Object value) {
            additionalProperties.put(Wire.nonNull(key, "key"), Wire.immutableJson(value));
            return this;
        }
        public TerminalTabEnd build() { return new TerminalTabEnd(this); }
    }
}
