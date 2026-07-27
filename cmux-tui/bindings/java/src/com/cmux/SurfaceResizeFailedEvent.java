package com.cmux;

public record SurfaceResizeFailedEvent(long surface, int cols, int rows, String error, Long retryAfterMs, Long reservationId) implements CmuxEvent {
    @Override
    public String event() {
        return "surface-resize-failed";
    }
}
