// Generated from cmux-tui/spec/sdk-schema.json. DO NOT EDIT.
package com.cmux.raw;


import java.util.Objects;


public final class LayoutUndoResult implements WireValue {
    public enum Kind { LAYOUT_UNDO_UNDONE, LAYOUT_UNDO_CONFIRMATION_REQUIRED }
    private final Kind kind;
    private final Object value;
    private LayoutUndoResult(Kind kind, Object value) {
        this.kind = kind;
        this.value = Objects.requireNonNull(value, "value");
    }
    public Kind kind() { return kind; }
    public Object value() { return value; }

    public static LayoutUndoResult ofLayoutUndoUndone(LayoutUndoUndone value) {
        return new LayoutUndoResult(Kind.LAYOUT_UNDO_UNDONE, value);
    }
    public boolean isLayoutUndoUndone() { return kind == Kind.LAYOUT_UNDO_UNDONE; }
    public LayoutUndoUndone layoutUndoUndone() {
        if (!isLayoutUndoUndone()) throw new IllegalStateException("LayoutUndoResult contains " + kind);
        return (LayoutUndoUndone) value;
    }

    public static LayoutUndoResult ofLayoutUndoConfirmationRequired(LayoutUndoConfirmationRequired value) {
        return new LayoutUndoResult(Kind.LAYOUT_UNDO_CONFIRMATION_REQUIRED, value);
    }
    public boolean isLayoutUndoConfirmationRequired() { return kind == Kind.LAYOUT_UNDO_CONFIRMATION_REQUIRED; }
    public LayoutUndoConfirmationRequired layoutUndoConfirmationRequired() {
        if (!isLayoutUndoConfirmationRequired()) throw new IllegalStateException("LayoutUndoResult contains " + kind);
        return (LayoutUndoConfirmationRequired) value;
    }

    public static LayoutUndoResult fromWire(Object raw) {
        CmuxDecodeException last = null;
        try {
            return ofLayoutUndoUndone(LayoutUndoUndone.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        try {
            return ofLayoutUndoConfirmationRequired(LayoutUndoConfirmationRequired.fromWire(raw));
        } catch (CmuxDecodeException error) {
            last = error;
        }
        throw new CmuxDecodeException("no LayoutUndoResult variant matched", last);
    }

    @Override
    public Object toWire() { return Wire.encode(value); }

    @Override
    public boolean equals(Object other) { return other instanceof LayoutUndoResult that && kind == that.kind && Objects.equals(value, that.value); }
    @Override public int hashCode() { return Objects.hash(kind, value); }
    @Override public String toString() { return "LayoutUndoResult[" + value + "]"; }
}
