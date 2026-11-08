// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;


public final class TerminalModifiers implements WireValue {
    private final boolean alt;
    private final boolean capsLock;
    private final boolean control;
    private final boolean numLock;
    private final boolean shift;
    private final boolean super_;

    private TerminalModifiers(Builder builder) {
        if (!builder.altSet) throw new IllegalArgumentException("alt is required");
        this.alt = builder.alt;
        if (!builder.capsLockSet) throw new IllegalArgumentException("caps_lock is required");
        this.capsLock = builder.capsLock;
        if (!builder.controlSet) throw new IllegalArgumentException("control is required");
        this.control = builder.control;
        if (!builder.numLockSet) throw new IllegalArgumentException("num_lock is required");
        this.numLock = builder.numLock;
        if (!builder.shiftSet) throw new IllegalArgumentException("shift is required");
        this.shift = builder.shift;
        if (!builder.super_Set) throw new IllegalArgumentException("super is required");
        this.super_ = builder.super_;
    }

    public static Builder builder() { return new Builder(); }

    public boolean alt() { return alt; }
    public boolean capsLock() { return capsLock; }
    public boolean control() { return control; }
    public boolean numLock() { return numLock; }
    public boolean shift() { return shift; }
    public boolean super_() { return super_; }

    public static TerminalModifiers fromWire(Object value) {
        Map<String, Object> object = Wire.object(value, "TerminalModifiers");
        Builder builder = builder();
        Object rawAlt = Wire.required(object, "alt");
        builder.alt(Wire.bool(rawAlt, "TerminalModifiers.alt"));
        Object rawCapsLock = Wire.required(object, "caps_lock");
        builder.capsLock(Wire.bool(rawCapsLock, "TerminalModifiers.caps_lock"));
        Object rawControl = Wire.required(object, "control");
        builder.control(Wire.bool(rawControl, "TerminalModifiers.control"));
        Object rawNumLock = Wire.required(object, "num_lock");
        builder.numLock(Wire.bool(rawNumLock, "TerminalModifiers.num_lock"));
        Object rawShift = Wire.required(object, "shift");
        builder.shift(Wire.bool(rawShift, "TerminalModifiers.shift"));
        Object rawSuper = Wire.required(object, "super");
        builder.super_(Wire.bool(rawSuper, "TerminalModifiers.super"));
        return builder.build();
    }

    @Override
    public Map<String, Object> toWire() {
        LinkedHashMap<String, Object> object = new LinkedHashMap<>();
        Wire.put(object, "alt", alt);
        Wire.put(object, "caps_lock", capsLock);
        Wire.put(object, "control", control);
        Wire.put(object, "num_lock", numLock);
        Wire.put(object, "shift", shift);
        Wire.put(object, "super", super_);
        return Collections.unmodifiableMap(object);
    }

    @Override
    public boolean equals(Object other) {
        if (!(other instanceof TerminalModifiers that)) return false;
        return Objects.equals(alt, that.alt) && Objects.equals(capsLock, that.capsLock) && Objects.equals(control, that.control) && Objects.equals(numLock, that.numLock) && Objects.equals(shift, that.shift) && Objects.equals(super_, that.super_);
    }

    @Override
    public int hashCode() { return Objects.hash(alt, capsLock, control, numLock, shift, super_); }

    @Override
    public String toString() { return "TerminalModifiers" + toWire(); }

    public static final class Builder {
        private Boolean alt;
        private boolean altSet;
        private Boolean capsLock;
        private boolean capsLockSet;
        private Boolean control;
        private boolean controlSet;
        private Boolean numLock;
        private boolean numLockSet;
        private Boolean shift;
        private boolean shiftSet;
        private Boolean super_;
        private boolean super_Set;

        public Builder alt(boolean value) {
            this.alt = value;
            this.altSet = true;
            return this;
        }
        public Builder capsLock(boolean value) {
            this.capsLock = value;
            this.capsLockSet = true;
            return this;
        }
        public Builder control(boolean value) {
            this.control = value;
            this.controlSet = true;
            return this;
        }
        public Builder numLock(boolean value) {
            this.numLock = value;
            this.numLockSet = true;
            return this;
        }
        public Builder shift(boolean value) {
            this.shift = value;
            this.shiftSet = true;
            return this;
        }
        public Builder super_(boolean value) {
            this.super_ = value;
            this.super_Set = true;
            return this;
        }
        public TerminalModifiers build() { return new TerminalModifiers(this); }
    }
}
