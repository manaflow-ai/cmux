// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Objects;


public final class Pane implements WireValue {
    public enum Kind { LIVE_PANE, DEAD_PANE }
    private final Kind kind;
    private final Object value;
    private Pane(Kind kind, Object value) {
        this.kind = kind;
        this.value = Objects.requireNonNull(value, "value");
    }
    public Kind kind() { return kind; }
    public Object value() { return value; }

    public static Pane ofLivePane(LivePane value) {
        return new Pane(Kind.LIVE_PANE, value);
    }
    public boolean isLivePane() { return kind == Kind.LIVE_PANE; }
    public LivePane livePane() {
        if (!isLivePane()) throw new IllegalStateException("Pane contains " + kind);
        return (LivePane) value;
    }

    public static Pane ofDeadPane(DeadPane value) {
        return new Pane(Kind.DEAD_PANE, value);
    }
    public boolean isDeadPane() { return kind == Kind.DEAD_PANE; }
    public DeadPane deadPane() {
        if (!isDeadPane()) throw new IllegalStateException("Pane contains " + kind);
        return (DeadPane) value;
    }

    public static Pane fromWire(Object raw) {
        CmuxDecodeException last = null;
        try {
            return ofLivePane(LivePane.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        try {
            return ofDeadPane(DeadPane.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        throw new CmuxDecodeException("no Pane variant matched", last);
    }

    @Override
    public Object toWire() { return Wire.encode(value); }

    @Override
    public boolean equals(Object other) { return other instanceof Pane that && kind == that.kind && Objects.equals(value, that.value); }
    @Override public int hashCode() { return Objects.hash(kind, value); }
    @Override public String toString() { return "Pane[" + value + "]"; }
}
