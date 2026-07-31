package com.cmux;

import java.util.Map;

public record ResizeSurfaceResult(boolean accepted, Long reservationId) {
    static ResizeSurfaceResult from(Map<String, Object> data) {
        return new ResizeSurfaceResult(
            !data.containsKey("accepted") || Boolean.TRUE.equals(data.get("accepted")),
            data.get("reservation_id") instanceof Number value ? value.longValue() : null
        );
    }
}
