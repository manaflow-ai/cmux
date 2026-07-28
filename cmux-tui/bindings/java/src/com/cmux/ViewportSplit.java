package com.cmux;

import java.util.Map;

public record ViewportSplit(long split, double width) {
    static ViewportSplit from(Map<String, Object> data) {
        Object width = data.get("width");
        double parsedWidth = width instanceof Number number
            ? number.doubleValue()
            : Double.parseDouble(String.valueOf(width));
        return new ViewportSplit(CmuxClient.asLong(data.get("split")), parsedWidth);
    }
}
