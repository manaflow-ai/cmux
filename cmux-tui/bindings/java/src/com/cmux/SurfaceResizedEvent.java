package com.cmux;

public record SurfaceResizedEvent(long surface, int cols, int rows, Long reservationId) implements CmuxEvent {
    public String event() {
        return "surface-resized";
    }
}
