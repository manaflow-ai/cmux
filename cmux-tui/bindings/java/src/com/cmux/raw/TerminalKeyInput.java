// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalKeyInput implements WireValue {
    private final Field<TerminalKeyAction> action;
    private final Field<String> baseLayoutCodepoint;
    private final Field<Boolean> composing;
    private final TerminalModifiers consumedMods;
    private final TerminalKey key;
    private final boolean macosOptionAsAlt;
    private final TerminalModifiers mods;
    private final Field<String> shiftedCodepoint;
    private final Field<String> unshiftedCodepoint;
    private final String utf8;

    private TerminalKeyInput(Builder builder) {
        this.action = builder.action;
        this.baseLayoutCodepoint = builder.baseLayoutCodepoint;
        this.composing = builder.composing;
        if (!builder.consumedModsSet) throw new IllegalArgumentException("consumed_mods is required");
        this.consumedMods = Wire.nonNull(builder.consumedMods, "consumed_mods");
        if (!builder.keySet) throw new IllegalArgumentException("key is required");
        this.key = Wire.nonNull(builder.key, "key");
        if (!builder.macosOptionAsAltSet) throw new IllegalArgumentException("macos_option_as_alt is required");
        this.macosOptionAsAlt = builder.macosOptionAsAlt;
        if (!builder.modsSet) throw new IllegalArgumentException("mods is required");
        this.mods = Wire.nonNull(builder.mods, "mods");
        this.shiftedCodepoint = builder.shiftedCodepoint;
        this.unshiftedCodepoint = builder.unshiftedCodepoint;
        if (!builder.utf8Set) throw new IllegalArgumentException("utf8 is required");
        this.utf8 = Wire.nonNull(builder.utf8, "utf8");
    }

    public static Builder builder() { return new Builder(); }

    public Field<TerminalKeyAction> action() { return action; }
    public Field<String> baseLayoutCodepoint() { return baseLayoutCodepoint; }
    public Field<Boolean> composing() { return composing; }
    public TerminalModifiers consumedMods() { return consumedMods; }
    public TerminalKey key() { return key; }
    public boolean macosOptionAsAlt() { return macosOptionAsAlt; }
    public TerminalModifiers mods() { return mods; }
    public Field<String> shiftedCodepoint() { return shiftedCodepoint; }
    public Field<String> unshiftedCodepoint() { return unshiftedCodepoint; }
    public String utf8() { return utf8; }

    public static TerminalKeyInput fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalKeyInput");
        Builder builder = builder();
        Object rawAction = Wire.optional(object, "action");
        if (!Wire.isMissing(rawAction)) {
            builder.action(rawAction == null ? null : TerminalKeyAction.fromWire(rawAction));
        }
        Object rawBaseLayoutCodepoint = Wire.optional(object, "base_layout_codepoint");
        if (!Wire.isMissing(rawBaseLayoutCodepoint)) {
            builder.baseLayoutCodepoint(rawBaseLayoutCodepoint == null ? null : Wire.string(rawBaseLayoutCodepoint, "TerminalKeyInput.base_layout_codepoint"));
        }
        Object rawComposing = Wire.optional(object, "composing");
        if (!Wire.isMissing(rawComposing)) {
            builder.composing(Wire.bool(rawComposing, "TerminalKeyInput.composing"));
        }
        Object rawConsumedMods = Wire.required(object, "consumed_mods");
        builder.consumedMods(TerminalModifiers.fromWire(rawConsumedMods));
        Object rawKey = Wire.required(object, "key");
        builder.key(TerminalKey.fromWire(rawKey));
        Object rawMacosOptionAsAlt = Wire.required(object, "macos_option_as_alt");
        builder.macosOptionAsAlt(Wire.bool(rawMacosOptionAsAlt, "TerminalKeyInput.macos_option_as_alt"));
        Object rawMods = Wire.required(object, "mods");
        builder.mods(TerminalModifiers.fromWire(rawMods));
        Object rawShiftedCodepoint = Wire.optional(object, "shifted_codepoint");
        if (!Wire.isMissing(rawShiftedCodepoint)) {
            builder.shiftedCodepoint(rawShiftedCodepoint == null ? null : Wire.string(rawShiftedCodepoint, "TerminalKeyInput.shifted_codepoint"));
        }
        Object rawUnshiftedCodepoint = Wire.optional(object, "unshifted_codepoint");
        if (!Wire.isMissing(rawUnshiftedCodepoint)) {
            builder.unshiftedCodepoint(rawUnshiftedCodepoint == null ? null : Wire.string(rawUnshiftedCodepoint, "TerminalKeyInput.unshifted_codepoint"));
        }
        Object rawUtf8 = Wire.required(object, "utf8");
        builder.utf8(Wire.string(rawUtf8, "TerminalKeyInput.utf8"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "action", action);
        Wire.put(object, "base_layout_codepoint", baseLayoutCodepoint);
        Wire.put(object, "composing", composing);
        Wire.put(object, "consumed_mods", consumedMods);
        Wire.put(object, "key", key);
        Wire.put(object, "macos_option_as_alt", macosOptionAsAlt);
        Wire.put(object, "mods", mods);
        Wire.put(object, "shifted_codepoint", shiftedCodepoint);
        Wire.put(object, "unshifted_codepoint", unshiftedCodepoint);
        Wire.put(object, "utf8", utf8);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalKeyInput that)) return false;
        return Objects.equals(action, that.action) && Objects.equals(baseLayoutCodepoint, that.baseLayoutCodepoint) && Objects.equals(composing, that.composing) && Objects.equals(consumedMods, that.consumedMods) && Objects.equals(key, that.key) && Objects.equals(macosOptionAsAlt, that.macosOptionAsAlt) && Objects.equals(mods, that.mods) && Objects.equals(shiftedCodepoint, that.shiftedCodepoint) && Objects.equals(unshiftedCodepoint, that.unshiftedCodepoint) && Objects.equals(utf8, that.utf8);
    }

    @Override
    public int hashCode() { return Objects.hash(action, baseLayoutCodepoint, composing, consumedMods, key, macosOptionAsAlt, mods, shiftedCodepoint, unshiftedCodepoint, utf8); }

    @Override
    public String toString() { return "TerminalKeyInput" + toWire(); }

    public static final class Builder {
        private Field<TerminalKeyAction> action = Field.omitted();
        private Field<String> baseLayoutCodepoint = Field.omitted();
        private Field<Boolean> composing = Field.omitted();
        private TerminalModifiers consumedMods;
        private boolean consumedModsSet;
        private TerminalKey key;
        private boolean keySet;
        private Boolean macosOptionAsAlt;
        private boolean macosOptionAsAltSet;
        private TerminalModifiers mods;
        private boolean modsSet;
        private Field<String> shiftedCodepoint = Field.omitted();
        private Field<String> unshiftedCodepoint = Field.omitted();
        private String utf8;
        private boolean utf8Set;

        public Builder action(TerminalKeyAction value) {
            this.action = Field.ofNullable(value);
            return this;
        }
        public Builder baseLayoutCodepoint(String value) {
            this.baseLayoutCodepoint = Field.ofNullable(value);
            return this;
        }
        public Builder composing(Boolean value) {
            this.composing = Field.of(value);
            return this;
        }
        public Builder consumedMods(TerminalModifiers value) {
            this.consumedMods = value;
            this.consumedModsSet = true;
            return this;
        }
        public Builder key(TerminalKey value) {
            this.key = value;
            this.keySet = true;
            return this;
        }
        public Builder macosOptionAsAlt(boolean value) {
            this.macosOptionAsAlt = value;
            this.macosOptionAsAltSet = true;
            return this;
        }
        public Builder mods(TerminalModifiers value) {
            this.mods = value;
            this.modsSet = true;
            return this;
        }
        public Builder shiftedCodepoint(String value) {
            this.shiftedCodepoint = Field.ofNullable(value);
            return this;
        }
        public Builder unshiftedCodepoint(String value) {
            this.unshiftedCodepoint = Field.ofNullable(value);
            return this;
        }
        public Builder utf8(String value) {
            this.utf8 = value;
            this.utf8Set = true;
            return this;
        }
        public TerminalKeyInput build() { return new TerminalKeyInput(this); }
    }
}
