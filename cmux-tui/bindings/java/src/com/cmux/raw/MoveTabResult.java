// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Objects;


public final class MoveTabResult implements WireValue {
    public enum Kind { PLACEMENT_RESULT, EMPTY_RESULT }
    private final Kind kind;
    private final Object value;
    private MoveTabResult(Kind kind, Object value) {
        this.kind = kind;
        this.value = Objects.requireNonNull(value, "value");
    }
    public Kind kind() { return kind; }
    public Object value() { return value; }

    public static MoveTabResult ofPlacementResult(PlacementResult value) {
        return new MoveTabResult(Kind.PLACEMENT_RESULT, value);
    }
    public boolean isPlacementResult() { return kind == Kind.PLACEMENT_RESULT; }
    public PlacementResult placementResult() {
        if (!isPlacementResult()) throw new IllegalStateException("MoveTabResult contains " + kind);
        return (PlacementResult) value;
    }

    public static MoveTabResult ofEmptyResult(EmptyResult value) {
        return new MoveTabResult(Kind.EMPTY_RESULT, value);
    }
    public boolean isEmptyResult() { return kind == Kind.EMPTY_RESULT; }
    public EmptyResult emptyResult() {
        if (!isEmptyResult()) throw new IllegalStateException("MoveTabResult contains " + kind);
        return (EmptyResult) value;
    }

    public static MoveTabResult fromWire(Object raw) {
        CmuxDecodeException last = null;
        try {
            return ofPlacementResult(PlacementResult.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        try {
            return ofEmptyResult(EmptyResult.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        throw new CmuxDecodeException("no MoveTabResult variant matched", last);
    }

    @Override
    public Object toWire() { return Wire.encode(value); }

    @Override
    public boolean equals(Object other) { return other instanceof MoveTabResult that && kind == that.kind && Objects.equals(value, that.value); }
    @Override public int hashCode() { return Objects.hash(kind, value); }
    @Override public String toString() { return "MoveTabResult[" + value + "]"; }
}
