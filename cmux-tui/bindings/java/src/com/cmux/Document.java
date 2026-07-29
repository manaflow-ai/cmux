package com.cmux;

import java.util.Map;

public record Document(Map<String, Object> fields) {
    public Document {
        fields = Map.copyOf(fields);
    }
}
