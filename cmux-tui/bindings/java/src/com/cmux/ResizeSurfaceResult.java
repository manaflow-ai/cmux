package com.cmux;

import java.util.Map;

public record ResizeSurfaceResult(boolean accepted) {
    static ResizeSurfaceResult from(Map<String, Object> data) {
        return new ResizeSurfaceResult(
            !data.containsKey("accepted") || Boolean.TRUE.equals(data.get("accepted"))
        );
    }
}
