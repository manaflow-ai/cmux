package com.cmux.raw;

import java.util.Map;

public record ViewportSplit(long split, double width) {
    static ViewportSplit from(Map<String, Object> data) {
        Object width = data.get("width");
        double parsedWidth = width instanceof Number number
            ? number.doubleValue()
            : Double.parseDouble(String.valueOf(width));
        return new ViewportSplit(
            Wire.int64(data.get("split"), "viewport split"),
            parsedWidth
        );
    }
}
